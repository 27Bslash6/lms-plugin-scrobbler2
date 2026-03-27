package Plugins::Scrobbler2::API;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use Encode qw(encode_utf8);
use JSON::XS qw(decode_json);
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

use constant API_URL => 'https://ws.audioscrobbler.com/2.0/';
use constant AUTH_URL => 'https://www.last.fm/api/auth/';

# Last.fm API error codes
use constant ERR_INVALID_SERVICE => 2;
use constant ERR_INVALID_METHOD  => 3;
use constant ERR_AUTH_FAILED     => 4;
use constant ERR_INVALID_PARAMS  => 6;
use constant ERR_OPERATION_FAILED => 8;
use constant ERR_INVALID_SK      => 9;
use constant ERR_INVALID_API_KEY => 10;
use constant ERR_SERVICE_OFFLINE => 11;
use constant ERR_INVALID_SIG    => 13;
use constant ERR_TOKEN_EXPIRED  => 14;
use constant ERR_NOT_ENOUGH_CONTENT => 16;
use constant ERR_SUSPENDED_KEY  => 26;
use constant ERR_RATE_LIMITED   => 29;

my $log = logger('plugin.scrobbler2');

sub generateSignature {
	my ($params, $secret) = @_;

	my $sig = '';
	for my $key (sort keys %{$params}) {
		next if $key eq 'format';
		$sig .= $key . $params->{$key};
	}
	$sig .= $secret;

	return md5_hex(encode_utf8($sig));
}

sub _buildQueryString {
	my ($params) = @_;
	return join('&', map { $_ . '=' . uri_escape_utf8($params->{$_}) } sort keys %{$params});
}

sub _addTrackParams {
	my ($params, $track, $suffix) = @_;
	$suffix //= '';
	$params->{"album$suffix"}       = $track->{album}       if $track->{album};
	$params->{"duration$suffix"}    = $track->{duration}     if $track->{duration};
	$params->{"trackNumber$suffix"} = $track->{tracknum}     if $track->{tracknum};
	$params->{"albumArtist$suffix"} = $track->{albumartist}  if $track->{albumartist};
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
		$http->get(API_URL . '?' . _buildQueryString($params));
	} else {
		$http->post(API_URL, 'Content-Type' => 'application/x-www-form-urlencoded', _buildQueryString($params));
	}
}

sub _handleResponse {
	my ($http, $cb, $ecb) = @_;

	my $content = $http->content;
	my $data;

	eval { $data = decode_json($content) };

	if ($@ || !$data) {
		$ecb->('Failed to parse Last.fm response', 0, 'TRANSIENT') if $ecb;
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
	my $category = categorizeError(0, $http->code // 0);

	main::INFOLOG && $log->is_info && $log->info("Last.fm HTTP error: $error");

	$ecb->($error, 0, $category) if $ecb;
}

sub categorizeError {
	my ($apiCode, $httpCode) = @_;

	return 'TRANSIENT' if ($httpCode && ($httpCode >= 500 || $httpCode == 0));
	return 'RATE_LIMITED' if $apiCode == ERR_RATE_LIMITED;
	return 'AUTH_FAILED' if $apiCode == ERR_AUTH_FAILED || $apiCode == ERR_INVALID_SK || $apiCode == ERR_TOKEN_EXPIRED;
	return 'TRANSIENT' if $apiCode == ERR_OPERATION_FAILED || $apiCode == ERR_SERVICE_OFFLINE || $apiCode == ERR_NOT_ENOUGH_CONTENT;
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
	_addTrackParams($params, $track);

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

		_addTrackParams($params, $track, "[$i]");

		$i++;
	}

	_request('track.scrobble', $params, $secret, $cb, $ecb);
}

1;
