package Plugins::Scrobbler2::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Control::Request;
use Time::HiRes;

use Plugins::Scrobbler2::API;

use constant MIN_TRACK_LENGTH => 30;
use constant SCROBBLE_TIME    => 240;
use constant QUEUE_INTERVAL   => 300;
use constant MAX_ATTEMPTS     => 10;
use constant MAX_QUEUE_SIZE   => 500;

my $prefs = preferences('plugin.scrobbler2');
my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.scrobbler2',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_SCROBBLER2_MODULE_NAME',
});

sub getDisplayName { return 'PLUGIN_SCROBBLER2_MODULE_NAME' }

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin();

	$prefs->init({
		api_key    => '',
		api_secret => '',
		accounts   => [],
		enable     => 1,
	});

	Slim::Control::Request::subscribe(\&_newsongCallback, [['playlist'], ['newsong']]);
	Slim::Control::Request::subscribe(\&_stopCallback,    [['playlist'], ['stop']]);
	Slim::Control::Request::subscribe(\&_pauseCallback,   [['playlist'], ['pause']]);

	if (main::WEBUI) {
		require Plugins::Scrobbler2::Settings;
		require Plugins::Scrobbler2::PlayerSettings;
		Plugins::Scrobbler2::Settings->new;
		Plugins::Scrobbler2::PlayerSettings->new;
	}

	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + QUEUE_INTERVAL, \&_queueFlushTimer);

	main::INFOLOG && $log->info("Scrobbler2 plugin initialized");
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&_newsongCallback);
	Slim::Control::Request::unsubscribe(\&_stopCallback);
	Slim::Control::Request::unsubscribe(\&_pauseCallback);
	Slim::Utils::Timers::killTimers(undef, \&_queueFlushTimer);

	for my $client (Slim::Player::Client::clients()) {
		Slim::Utils::Timers::killTimers($client, \&_checkScrobble);
		Slim::Utils::Timers::killTimers($client, \&_retryQueue);
		$client->master->pluginData(scrobbler2_track => undef);
		$client->master->pluginData(scrobbler2_processing => 0);
		$client->master->pluginData(scrobbler2_auth_failed => 0);
	}
}

# --- Helpers ---

sub _getCredentials {
	my $apiKey = $prefs->get('api_key');
	my $secret = $prefs->get('api_secret');
	return unless $apiKey && $secret;
	return ($apiKey, $secret);
}

sub _scrobbleThreshold {
	my $duration = shift;
	my $t = $duration / 2;
	return $t > SCROBBLE_TIME ? SCROBBLE_TIME : $t;
}

sub getAccount {
	my $client = shift;
	return unless $client;

	# Check auth failure flag
	return if $client->master->pluginData('scrobbler2_auth_failed');

	my $username = $prefs->client($client)->get('account');
	return unless $username;

	my $accounts = $prefs->get('accounts') || [];
	for my $acct (@{$accounts}) {
		return $acct if $acct->{username} eq $username;
	}

	return;
}

# --- Track Metadata ---

sub _getTrackMeta {
	my $client = shift;

	my $url = Slim::Player::Playlist::url($client);
	return unless $url;

	my $track = Slim::Schema->objectForUrl({ url => $url });

	# For remote/streaming tracks (TIDAL, etc), objectForUrl may return undef
	# Try protocol handler directly first for these
	unless ($track) {
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
		if ($handler && $handler->can('getMetadataFor')) {
			my $rmeta = $handler->getMetadataFor($client, $url, 'forceCurrent');
			if ($rmeta && $rmeta->{artist} && $rmeta->{title}) {
				return {
					artist      => $rmeta->{artist},
					title       => $rmeta->{title},
					album       => $rmeta->{album}       || '',
					duration    => $rmeta->{duration}    || 0,
					albumartist => $rmeta->{albumartist} || '',
					tracknum    => '',
				};
			}
		}
		return;
	}

	my $meta = {
		artist      => $track->artistName || '',
		title       => $track->title || '',
		album       => ($track->album && $track->album->get_column('title')) || '',
		duration    => $track->secs || 0,
		tracknum    => $track->tracknum || '',
		albumartist => ($track->can('albumArtistsString') ? ($track->albumArtistsString || '') : ''),
	};

	# Remote/streaming tracks: enrich from protocol handler if available
	if ($track->remote) {
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
		if ($handler && $handler->can('getMetadataFor')) {
			my $rmeta = $handler->getMetadataFor($client, $url, 'forceCurrent');
			if ($rmeta && $rmeta->{artist} && $rmeta->{title}) {
				$meta->{artist}      = $rmeta->{artist};
				$meta->{title}       = $rmeta->{title};
				$meta->{album}       = $rmeta->{album}       // $meta->{album};
				$meta->{duration}    = $rmeta->{duration}    // $meta->{duration};
				$meta->{albumartist} = $rmeta->{albumartist} // '';
			}
		}
	}

	return $meta;
}

# --- Playback Event Callbacks ---

sub _newsongCallback {
	my $request = shift;
	my $client = $request->client() || return;

	return unless $prefs->get('enable');

	# Synced players: only process on master
	return if $client->isSynced() && !Slim::Player::Sync::isMaster($client);

	my $account = getAccount($client) || return;

	# Cancel any pending scrobble timer for this player
	Slim::Utils::Timers::killTimers($client, \&_checkScrobble);

	my $meta = _getTrackMeta($client) || return;
	return unless $meta->{artist} && $meta->{title};
	return unless $meta->{duration} >= MIN_TRACK_LENGTH;

	my ($apiKey, $secret) = _getCredentials() or return;

	# Send now playing (fire-and-forget)
	Plugins::Scrobbler2::API::updateNowPlaying(
		$apiKey, $secret, $account->{sk}, $meta,
		sub { main::DEBUGLOG && $log->is_debug && $log->debug("Now playing: $meta->{artist} - $meta->{title}") },
		sub {
			my ($error, $code, $category) = @_;
			main::INFOLOG && $log->info("Now playing failed: $error");
			_handleAuthError($client, $code, $category);
		},
	);

	# Store track info and set scrobble timer
	$client->master->pluginData(scrobbler2_track => {
		%{$meta},
		timestamp  => time(),
		start_time => Time::HiRes::time(),
	});

	Slim::Utils::Timers::setTimer(
		$client,
		Time::HiRes::time() + _scrobbleThreshold($meta->{duration}),
		\&_checkScrobble,
	);

	main::DEBUGLOG && $log->is_debug && $log->debug(
		"Tracking: $meta->{artist} - $meta->{title}"
	);
}

sub _stopCallback {
	my $request = shift;
	my $client = $request->client() || return;

	# Synced players: only process on master
	return if $client->isSynced() && !Slim::Player::Sync::isMaster($client);

	Slim::Utils::Timers::killTimers($client, \&_checkScrobble);
	$client->master->pluginData(scrobbler2_track => undef);
}

sub _pauseCallback {
	my $request = shift;
	my $client = $request->client() || return;

	# Synced players: only process on master
	return if $client->isSynced() && !Slim::Player::Sync::isMaster($client);

	my $paused = $request->getParam('_newvalue');
	return unless defined $paused;

	if ($paused) {
		Slim::Utils::Timers::killTimers($client, \&_checkScrobble);
	} else {
		# Unpaused: recalculate and reset timer
		my $trackData = $client->master->pluginData('scrobbler2_track');
		return unless $trackData;

		my $elapsed = Slim::Player::Source::songTime($client);
		my $remaining = _scrobbleThreshold($trackData->{duration}) - $elapsed;

		if ($remaining <= 0) {
			_checkScrobble($client);
			return;
		}

		Slim::Utils::Timers::setTimer(
			$client,
			Time::HiRes::time() + $remaining,
			\&_checkScrobble,
		);
	}
}

# --- Scrobble Check ---

sub _checkScrobble {
	my $client = shift;
	return unless $client;

	my $trackData = $client->master->pluginData('scrobbler2_track') || return;
	my $account = getAccount($client) || return;

	return if $client->isStopped();

	my $currentMeta = _getTrackMeta($client);
	return unless $currentMeta;
	return unless $currentMeta->{title} eq $trackData->{title}
		&& $currentMeta->{artist} eq $trackData->{artist};

	my $elapsed = Slim::Player::Source::songTime($client);
	my $required = _scrobbleThreshold($trackData->{duration});

	if ($elapsed < $required) {
		Slim::Utils::Timers::setTimer(
			$client,
			Time::HiRes::time() + ($required - $elapsed) + 1,
			\&_checkScrobble,
		);
		return;
	}

	_addToQueue($client, $trackData);
	$client->master->pluginData(scrobbler2_track => undef);

	main::INFOLOG && $log->info("Queued scrobble: $trackData->{artist} - $trackData->{title}");

	_processQueue($client);
}

# --- Queue Management ---

sub _getQueue {
	my $client = shift;
	return $prefs->client($client)->get('queue') || [];
}

sub _setQueue {
	my ($client, $queue) = @_;
	$prefs->client($client)->set(queue => $queue);
}

sub _addToQueue {
	my ($client, $trackData) = @_;

	my $queue = _getQueue($client);

	# Cap queue size — drop oldest if full
	while (scalar @{$queue} >= MAX_QUEUE_SIZE) {
		my $dropped = shift @{$queue};
		$log->warn("Queue full, dropping oldest: $dropped->{artist} - $dropped->{title}");
	}

	push @{$queue}, {
		artist      => $trackData->{artist},
		title       => $trackData->{title},
		album       => $trackData->{album} || '',
		duration    => $trackData->{duration} || 0,
		tracknum    => $trackData->{tracknum} || '',
		albumartist => $trackData->{albumartist} || '',
		timestamp   => $trackData->{timestamp},
		attempts    => 0,
	};
	_setQueue($client, $queue);
}

sub _processQueue {
	my $client = shift;
	return unless $client;

	# Prevent concurrent processing
	return if $client->master->pluginData('scrobbler2_processing');

	my $account = getAccount($client) || return;
	my $queue = _getQueue($client);
	return unless @{$queue};

	my ($apiKey, $secret) = _getCredentials() or return;

	$client->master->pluginData(scrobbler2_processing => 1);

	# Work on a copy — don't mutate prefs directly
	my @remaining = @{$queue};
	my @batch = splice(@remaining, 0, 50);

	Plugins::Scrobbler2::API::scrobble(
		$apiKey, $secret, $account->{sk}, \@batch,
		sub {
			my $data = shift;
			eval {
				my $accepted = $data->{scrobbles}{'@attr'}{accepted} || 0;
				my $ignored = $data->{scrobbles}{'@attr'}{ignored} || 0;

				main::INFOLOG && $log->info("Scrobbled: $accepted accepted, $ignored ignored");

				_setQueue($client, \@remaining);

				_processQueue($client) if @remaining;
			};
			$log->error("Scrobble callback error: $@") if $@;
			$client->master->pluginData(scrobbler2_processing => 0);
		},
		sub {
			my ($error, $code, $category) = @_;
			$category ||= 'TRANSIENT';
			eval {
				main::INFOLOG && $log->info("Scrobble submit failed: $error ($category)");

				if ($category eq 'PERMANENT' || $category eq 'AUTH_FAILED') {
					$log->warn("Dropping batch of " . scalar(@batch) . " scrobbles: $error ($category)");
				} else {
					for my $item (@batch) {
						$item->{attempts}++;
						if ($item->{attempts} < MAX_ATTEMPTS) {
							unshift @remaining, $item;
						} else {
							$log->warn("Dropping scrobble after ${\MAX_ATTEMPTS} attempts: $item->{artist} - $item->{title}");
						}
					}
				}
				_setQueue($client, \@remaining);

				_handleAuthError($client, $code, $category);

				if (($category eq 'TRANSIENT' || $category eq 'RATE_LIMITED') && @remaining) {
					my $delay = _backoffDelay($batch[0]->{attempts});
					Slim::Utils::Timers::killTimers($client, \&_retryQueue);
					Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $delay, \&_retryQueue);
				}
			};
			$log->error("Scrobble error callback error: $@") if $@;
			$client->master->pluginData(scrobbler2_processing => 0);
		},
	);
}

sub _retryQueue {
	my $client = shift;
	_processQueue($client);
}

sub _queueFlushTimer {
	for my $client (Slim::Player::Client::clients()) {
		my $queue = _getQueue($client);
		_processQueue($client) if $queue && @{$queue};
	}

	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + QUEUE_INTERVAL, \&_queueFlushTimer);
}

sub _backoffDelay {
	my $attempt = shift || 1;
	my $delay = 60 * (2 ** ($attempt - 1));  # seconds
	return $delay > 7200 ? 7200 : $delay;    # cap at 2 hours
}

sub _handleAuthError {
	my ($client, $code, $category) = @_;
	return unless $category && $category eq 'AUTH_FAILED';

	# Set flag to stop further API calls until re-authorized
	$client->master->pluginData(scrobbler2_auth_failed => 1);

	$log->warn("Last.fm session expired for player " . $client->name . ". Re-authorize in plugin settings.");
}

# Called from Settings.pm when account is re-authorized
sub clearAuthFailure {
	my $client = shift;
	$client->master->pluginData(scrobbler2_auth_failed => 0) if $client;
}

1;
