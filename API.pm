package Plugins::Scrobbler2::API;

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS qw(decode_json);
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

use constant API_URL => 'https://ws.audioscrobbler.com/2.0/';
use constant AUTH_URL => 'https://www.last.fm/api/auth/';

my $log = logger('plugin.scrobbler2');

sub generateSignature {
	my ($params, $secret) = @_;

	my $sig = '';
	for my $key (sort keys %{$params}) {
		next if $key eq 'format';
		$sig .= $key . $params->{$key};
	}
	$sig .= $secret;

	return md5_hex($sig);
}

sub _request {
	my ($method, $params, $secret, $cb, $ecb, $httpMethod) = @_;

	$httpMethod ||= 'POST';
	$params->{method} = $method;
	$params->{format} = 'json';
	$params->{api_sig} = generateSignature($params, $secret);

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub { _handleResponse(shift, $cb, $ecb) },
		sub { _handleError(shift, $ecb) },
		{ timeout => 30 },
	);

	if ($httpMethod eq 'GET') {
		my $url = API_URL . '?' . join('&', map { $_ . '=' . uri_escape_utf8($params->{$_}) } keys %{$params});
		$http->get($url);
	} else {
		my $body = join('&', map { $_ . '=' . uri_escape_utf8($params->{$_}) } keys %{$params});
		$http->post(API_URL, 'Content-Type' => 'application/x-www-form-urlencoded', $body);
	}
}

sub _handleResponse {
	my ($http, $cb, $ecb) = @_;

	my $content = $http->content;
	my $data;

	eval { $data = decode_json($content) };

	if ($@ || !$data) {
		$ecb->('Failed to parse Last.fm response') if $ecb;
		return;
	}

	if ($data->{error}) {
		my $code = $data->{error};
		my $msg = $data->{message} || 'Unknown error';
		my $category = categorizeError($code, $http->code);

		main::DEBUGLOG && $log->is_debug && $log->debug("Last.fm API error $code: $msg ($category)");

		$ecb->($msg, $code, $category) if $ecb;
		return;
	}

	$cb->($data) if $cb;
}

sub _handleError {
	my ($http, $ecb) = @_;

	my $error = $http->error || 'Connection failed';
	my $category = categorizeError(0, $http->code || 0);

	main::INFOLOG && $log->is_info && $log->info("Last.fm HTTP error: $error");

	$ecb->($error, 0, $category) if $ecb;
}

sub categorizeError {
	my ($apiCode, $httpCode) = @_;

	return 'TRANSIENT' if ($httpCode && ($httpCode >= 500 || $httpCode == 0));
	return 'RATE_LIMITED' if $apiCode == 29;
	return 'AUTH_FAILED' if $apiCode == 4 || $apiCode == 9 || $apiCode == 14;
	return 'TRANSIENT' if $apiCode == 8 || $apiCode == 11 || $apiCode == 16;
	return 'PERMANENT' if $apiCode;
	return 'TRANSIENT';
}

# --- Authentication ---

sub getToken {
	my ($apiKey, $secret, $cb, $ecb) = @_;

	_request('auth.getToken', { api_key => $apiKey }, $secret, $cb, $ecb, 'GET');
}

sub getSession {
	my ($apiKey, $secret, $token, $cb, $ecb) = @_;

	_request('auth.getSession', { api_key => $apiKey, token => $token }, $secret, $cb, $ecb, 'GET');
}

sub getAuthURL {
	my ($apiKey, $token) = @_;

	return AUTH_URL . '?api_key=' . uri_escape_utf8($apiKey) . '&token=' . uri_escape_utf8($token);
}

# --- Scrobbling ---

sub updateNowPlaying {
	my ($apiKey, $secret, $sk, $track, $cb, $ecb) = @_;

	my $params = {
		api_key => $apiKey,
		sk      => $sk,
		artist  => $track->{artist},
		track   => $track->{title},
	};
	$params->{album}       = $track->{album}    if $track->{album};
	$params->{duration}    = $track->{duration}  if $track->{duration};
	$params->{trackNumber} = $track->{tracknum}  if $track->{tracknum};
	$params->{albumArtist} = $track->{albumartist} if $track->{albumartist};

	_request('track.updateNowPlaying', $params, $secret, $cb, $ecb);
}

sub scrobble {
	my ($apiKey, $secret, $sk, $tracks, $cb, $ecb) = @_;

	my $params = {
		api_key => $apiKey,
		sk      => $sk,
	};

	my $i = 0;
	for my $track (@{$tracks}) {
		last if $i >= 50;

		$params->{"artist[$i]"}    = $track->{artist};
		$params->{"track[$i]"}     = $track->{title};
		$params->{"timestamp[$i]"} = $track->{timestamp};

		$params->{"album[$i]"}       = $track->{album}      if $track->{album};
		$params->{"duration[$i]"}    = $track->{duration}    if $track->{duration};
		$params->{"trackNumber[$i]"} = $track->{tracknum}    if $track->{tracknum};
		$params->{"albumArtist[$i]"} = $track->{albumartist} if $track->{albumartist};

		$i++;
	}

	_request('track.scrobble', $params, $secret, $cb, $ecb);
}

1;
