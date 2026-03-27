package Plugins::Scrobbler2::Settings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use JSON::XS qw(decode_json);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::Scrobbler2::API;

my $prefs = preferences('plugin.scrobbler2');
my $log = logger('plugin.scrobbler2');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SCROBBLER2_MODULE_NAME');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Scrobbler2/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(enable api_key api_secret));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	my $apiKey = $params->{pref_api_key} || $prefs->get('api_key') || '';
	my $secret = $params->{pref_api_secret} || $prefs->get('api_secret') || '';

	$params->{accounts} = $prefs->get('accounts') || [];

	# Handle account removal
	if ($params->{delete}) {
		my $toDelete = ref $params->{delete} ? $params->{delete} : [$params->{delete}];
		my $accounts = $prefs->get('accounts') || [];
		$accounts = [grep { my $acct = $_; !grep { $_ eq $acct->{username} } @{$toDelete} } @{$accounts}];
		$prefs->set('accounts', $accounts);
		$params->{accounts} = $accounts;
	}

	# Step 1: Request auth token
	if ($params->{addAccount}) {
		unless ($apiKey && $secret) {
			$params->{error} = 'API key and secret are required';
		} else {
			Plugins::Scrobbler2::API::getToken($apiKey, $secret,
				sub {
					my $data = shift;
					my $token = $data->{token};

					$params->{auth_pending} = 1;
					$params->{auth_token} = $token;
					$params->{auth_url} = Plugins::Scrobbler2::API::getAuthURL($apiKey, $token);

					my $body = $class->SUPER::handler($client, $params);
					$callback->($client, $params, $body, @args);
				},
				sub {
					my ($error) = @_;
					$params->{error} = $error;

					my $body = $class->SUPER::handler($client, $params);
					$callback->($client, $params, $body, @args);
				},
			);
			return;
		}
	}

	# Step 2: Complete authorization (exchange token for session)
	if ($params->{completeAuth} && $params->{auth_token}) {
		unless ($apiKey && $secret) {
			$params->{error} = 'API key and secret are required';
		} else {
			Plugins::Scrobbler2::API::getSession($apiKey, $secret, $params->{auth_token},
				sub {
					my $data = shift;
					my $session = $data->{session};

					my $accounts = $prefs->get('accounts') || [];

					# Replace existing account or add new
					my $found = 0;
					for my $acct (@{$accounts}) {
						if ($acct->{username} eq $session->{name}) {
							$acct->{sk} = $session->{key};
							$found = 1;
							last;
						}
					}
					unless ($found) {
						push @{$accounts}, {
							username => $session->{name},
							sk       => $session->{key},
						};
					}

					$prefs->set('accounts', $accounts);
					$params->{accounts} = $accounts;
					$params->{auth_success} = 1;

					main::INFOLOG && $log->info("Authorized Last.fm account: $session->{name}");

					my $body = $class->SUPER::handler($client, $params);
					$callback->($client, $params, $body, @args);
				},
				sub {
					my ($error) = @_;
					$params->{auth_error} = $error;

					my $body = $class->SUPER::handler($client, $params);
					$callback->($client, $params, $body, @args);
				},
			);
			return;
		}
	}

	return $class->SUPER::handler($client, $params);
}

1;
