package Plugins::Scrobbler2::PlayerSettings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.scrobbler2');

sub name {
	return 'PLUGIN_SCROBBLER2_MODULE_NAME';
}

sub needsClient {
	return 1;
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Scrobbler2/settings/player.html');
}

sub handler {
	my ($class, $client, $params) = @_;

	if ($client) {
		$params->{accounts} = $prefs->get('accounts') || [];
		$params->{currentAccount} = $prefs->client($client)->get('account') || '';

		if ($params->{saveSettings} && defined $params->{pref_account}) {
			$prefs->client($client)->set('account', $params->{pref_account});
			$params->{currentAccount} = $params->{pref_account};
		}
	}

	return $class->SUPER::handler($client, $params);
}

1;
