package Plugins::Scrobbler2::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Control::Request;
use URI::Escape qw(uri_escape_utf8 uri_unescape);
use Time::HiRes;

use Plugins::Scrobbler2::API;

use constant MIN_TRACK_LENGTH => 30;
use constant SCROBBLE_TIME    => 240;
use constant QUEUE_INTERVAL   => 300;
use constant MAX_ATTEMPTS     => 10;

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

	# Periodic queue flush
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + QUEUE_INTERVAL, \&_queueFlushTimer);

	main::INFOLOG && $log->info("Scrobbler2 plugin initialized");
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&_newsongCallback);
	Slim::Control::Request::unsubscribe(\&_stopCallback);
	Slim::Control::Request::unsubscribe(\&_pauseCallback);
	Slim::Utils::Timers::killTimers(undef, \&_queueFlushTimer);
}

# --- Account Helpers ---

sub getAccount {
	my $client = shift;
	return unless $client;

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
	return unless $track;

	my $meta = {
		artist   => $track->artistName || '',
		title    => $track->title || '',
		album    => ($track->album && $track->album->get_column('title')) || '',
		duration => $track->secs || 0,
		tracknum => $track->tracknum || '',
	};

	# Remote/streaming tracks: try protocol handler for richer metadata
	if ($track->remote) {
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
		if ($handler && $handler->can('getMetadataFor')) {
			my $rmeta = $handler->getMetadataFor($client, $url, 'forceCurrent');
			if ($rmeta && $rmeta->{artist} && $rmeta->{title}) {
				$meta->{artist}      = $rmeta->{artist}      if $rmeta->{artist};
				$meta->{title}       = $rmeta->{title}       if $rmeta->{title};
				$meta->{album}       = $rmeta->{album}       if $rmeta->{album};
				$meta->{duration}    = $rmeta->{duration}    if $rmeta->{duration};
				$meta->{albumartist} = $rmeta->{albumartist} if $rmeta->{albumartist};
			}
		}
	}

	return $meta;
}

# --- Playback Event Callbacks ---

sub _newsongCallback {
	my $request = shift;
	my $client = $request->client() || return;

	# Synced players: only process on master
	return if $client->isSynced() && !Slim::Player::Sync::isMaster($client);

	my $account = getAccount($client) || return;

	# Cancel any pending scrobble timer for this player
	Slim::Utils::Timers::killTimers($client, \&_checkScrobble);

	my $meta = _getTrackMeta($client) || return;
	return unless $meta->{artist} && $meta->{title};
	return unless $meta->{duration} >= MIN_TRACK_LENGTH;

	# Send now playing
	my $apiKey = $prefs->get('api_key');
	my $secret = $prefs->get('api_secret');

	Plugins::Scrobbler2::API::updateNowPlaying(
		$apiKey, $secret, $account->{sk}, $meta,
		sub { main::DEBUGLOG && $log->is_debug && $log->debug("Now playing: $meta->{artist} - $meta->{title}") },
		sub {
			my ($error, $code, $category) = @_;
			main::INFOLOG && $log->info("Now playing failed: $error");
			_handleAuthError($client, $code, $category);
		},
	);

	# Set scrobble timer
	my $checkTime = $meta->{duration} / 2;
	$checkTime = SCROBBLE_TIME if $checkTime > SCROBBLE_TIME;

	# Store track info for scrobble check
	$client->master->pluginData(scrobbler2_track => {
		%{$meta},
		timestamp  => time(),
		start_time => Time::HiRes::time(),
	});

	Slim::Utils::Timers::setTimer(
		$client,
		Time::HiRes::time() + $checkTime,
		\&_checkScrobble,
	);

	main::DEBUGLOG && $log->is_debug && $log->debug(
		"Tracking: $meta->{artist} - $meta->{title} (scrobble check in ${checkTime}s)"
	);
}

sub _stopCallback {
	my $request = shift;
	my $client = $request->client() || return;

	Slim::Utils::Timers::killTimers($client, \&_checkScrobble);
	$client->master->pluginData(scrobbler2_track => undef);
}

sub _pauseCallback {
	my $request = shift;
	my $client = $request->client() || return;

	my $paused = $request->getParam('_newvalue');
	return unless defined $paused;

	if ($paused) {
		# Paused: kill timer, save remaining time
		Slim::Utils::Timers::killTimers($client, \&_checkScrobble);
	} else {
		# Unpaused: recalculate and reset timer
		my $trackData = $client->master->pluginData('scrobbler2_track');
		return unless $trackData;

		my $elapsed = Slim::Player::Source::songTime($client);
		my $checkTime = $trackData->{duration} / 2;
		$checkTime = SCROBBLE_TIME if $checkTime > SCROBBLE_TIME;

		my $remaining = $checkTime - $elapsed;
		return if $remaining <= 0;  # Already past scrobble point

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

	# Verify track is still playing
	return if $client->isStopped();

	my $currentMeta = _getTrackMeta($client);
	return unless $currentMeta;
	return unless $currentMeta->{title} eq $trackData->{title}
		&& $currentMeta->{artist} eq $trackData->{artist};

	# Check elapsed time
	my $elapsed = Slim::Player::Source::songTime($client);
	my $required = $trackData->{duration} / 2;
	$required = SCROBBLE_TIME if $required > SCROBBLE_TIME;

	if ($elapsed < $required) {
		# Not enough time yet, reschedule
		my $remaining = $required - $elapsed;
		Slim::Utils::Timers::setTimer(
			$client,
			Time::HiRes::time() + $remaining + 1,
			\&_checkScrobble,
		);
		return;
	}

	# Queue the scrobble
	_addToQueue($client, $trackData);
	$client->master->pluginData(scrobbler2_track => undef);

	main::INFOLOG && $log->info("Queued scrobble: $trackData->{artist} - $trackData->{title}");

	# Trigger queue flush
	_processQueue($client);
}

# --- Queue Management ---

sub _getQueue {
	my $client = shift;
	return $prefs->client($client)->get('scrobbler2_queue') || [];
}

sub _setQueue {
	my ($client, $queue) = @_;
	$prefs->client($client)->set(scrobbler2_queue => $queue);
}

sub _addToQueue {
	my ($client, $trackData) = @_;

	my $queue = _getQueue($client);
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

	my $account = getAccount($client) || return;
	my $queue = _getQueue($client);
	return unless @{$queue};

	my $apiKey = $prefs->get('api_key');
	my $secret = $prefs->get('api_secret');

	# Submit up to 50 tracks
	my @batch = splice(@{$queue}, 0, 50);

	Plugins::Scrobbler2::API::scrobble(
		$apiKey, $secret, $account->{sk}, \@batch,
		sub {
			my $data = shift;
			my $accepted = $data->{scrobbles}{'@attr'}{accepted} || 0;
			my $ignored = $data->{scrobbles}{'@attr'}{ignored} || 0;

			main::INFOLOG && $log->info("Scrobbled: $accepted accepted, $ignored ignored");

			# Save remaining queue
			_setQueue($client, $queue);

			# Process more if queue isn't empty
			_processQueue($client) if @{$queue};
		},
		sub {
			my ($error, $code, $category) = @_;
			main::INFOLOG && $log->info("Scrobble submit failed: $error ($category)");

			# Re-queue failed items with incremented attempt counter
			for my $item (@batch) {
				$item->{attempts}++;
				if ($item->{attempts} < MAX_ATTEMPTS) {
					unshift @{$queue}, $item;
				} else {
					$log->warn("Dropping scrobble after ${\MAX_ATTEMPTS} attempts: $item->{artist} - $item->{title}");
				}
			}
			_setQueue($client, $queue);

			_handleAuthError($client, $code, $category);

			# Schedule retry with backoff
			if ($category eq 'TRANSIENT' || $category eq 'RATE_LIMITED') {
				my $delay = _backoffDelay($batch[0]->{attempts});
				Slim::Utils::Timers::killTimers($client, \&_retryQueue);
				Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $delay, \&_retryQueue);
			}
		},
	);
}

sub _retryQueue {
	my $client = shift;
	_processQueue($client);
}

sub _queueFlushTimer {
	# Flush queues for all connected clients
	for my $client (Slim::Player::Client::clients()) {
		my $queue = _getQueue($client);
		_processQueue($client) if $queue && @{$queue};
	}

	# Reschedule
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + QUEUE_INTERVAL, \&_queueFlushTimer);
}

sub _backoffDelay {
	my $attempt = shift || 1;
	my $delay = 60 * (2 ** ($attempt - 1));
	return $delay > 7200 ? 7200 : $delay;
}

sub _handleAuthError {
	my ($client, $code, $category) = @_;
	return unless $category && $category eq 'AUTH_FAILED';

	$log->warn("Last.fm session expired for player " . $client->name . ". Please re-authorize.");
}

1;
