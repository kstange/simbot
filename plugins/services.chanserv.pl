# SimBot NickServ/ChanServ style Services Plugin
#
# Copyright (C) 2004, Vincent Gevers <http://allowee.net/>
# Copyright (C) 2005, Kevin Stange   <kevin@simguy.net>
#
# This program is free software; you can redistribute it and/or modify
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
# NOTE: This plugin has only been heavily tested on a Freenode.  Additional
#       testing on other networks would be greatly appreciated.
#
# TODO: ChanServ/NickServ works basically the same everywhere, but the message
#       strings tend to vary.  Form these into lists to avoid messy matching
#       in the logic below.

package SimBot::plugin::services::chanserv;

use warnings;
use strict;

# Start with the assumption Services are online, we are not locked out, and
# we are not logged in, and we are not shut up.
our $services_online = 0;
our $logged_in       = 0;
our $locked_out      = 0;
our $shut_up         = 0;

# SERVICES_LOGIN: Here, we log into nickserv if we have a services username and
# password, since logging in would be tricky, at best, without them.
sub services_login {
	my $kernel = $_[0];
	my $pass = &SimBot::option('services', 'pass');

    if ($pass) {
		&SimBot::debug(3, "Logging into services...\n");
		$kernel->post(bot => sl => "nickserv identify $pass");
    }
}

sub registration_check {
    my ($kernel, undef, undef, $newnick) = @_;
	my $want = &SimBot::option('global', 'nickname');
	my $me   = $SimBot::chosen_nick;

	if ($me eq $newnick && $me eq $want) {
		&SimBot::debug(3, "Checking nickname availability...\n");
		$kernel->post(bot => sl => "nickserv info");
	}
}

# CHECK_RESPONSE: When we try to log in or run a command, services will tell us
# something.  Here, we handle different possible cases.
sub check_response {
    my ($kernel, $nick, undef, $text) = @_;
	my $pass = &SimBot::option('services', 'pass');
	my $me   = $SimBot::chosen_nick;
	my $want = &SimBot::option('global', 'nickname');
	my $chan = &SimBot::option('network', 'channel');
    if (lc($nick) eq lc("NickServ")) {
		$services_online = 1;

		if ($text =~ /is( not|n\'t) registered/i) {
			# Try to register!!
			if ($me eq $want) {
				&SimBot::debug(3, "Nickname $me is not registered; trying to register it now...\n");
				$kernel->post(bot => sl => "nickserv register $pass");
			}
		} elsif ($text =~ /Nickname: ([^\s]+)/i) {
			&SimBot::debug(4, "Nickname $1 is already registered; waiting for nickserv to ask for us to identify...\n");
		} elsif ($text =~ /Your nickname is now registered/i) {
			&SimBot::debug(3, "Nickname $me registered successfully.\n");
			$logged_in = 1;
			if ($locked_out) {
				&request_unban($kernel, undef, $chan);
			}
			if ($shut_up) {
				&request_voice($kernel, undef, $chan);
			}
		} elsif ($text =~ /Password incorrect/i) {
			if ($logged_in == 0) {
                &SimBot::debug(1, "Services reports login failure.\n");
			} else {
				&SimBot::debug(1, "Services command failed: Incorrect password.\n");
			}
		} elsif ($text =~ /This nickname is owned by someone else/i) {
			$logged_in = 0;
			&services_login($kernel);
		} elsif ($text =~ /you are now recognized/i) {
			&SimBot::debug(3, "Services reports successful login.\n");
			$logged_in = 1;
			if ($locked_out) {
				&request_unban($kernel, undef, $chan);
			}
			if ($shut_up) {
				&request_voice($kernel, undef, $chan);
			}
		} elsif ($text =~ /You have already identified/i) {
			&SimBot::debug(2, "Services reports already logged in.\n");
			$logged_in = 1;
		} elsif ($text =~ /Access denied/i) {
			&SimBot::debug(2, "Services reports not yet logged in.\n");
			$logged_in = 0;
			&services_login($kernel);
        } elsif ($text =~ m/Your nickname is not yet authenticated/i) {
            &SimBot::debug(1, "Services reports: $text");
		}
    }

    if (lc($nick) eq lc("ChanServ")) {
		$services_online = 1;
		if ($text =~ /bans matching .* cleared on (\#.*)/i) {
			my $chan = $1;
			&SimBot::debug(3, "Services reports successful unban command.\n");
			$kernel->post(bot => join => $chan);
		} elsif ($text =~ /Password identification is required/i) {
			&SimBot::debug(2, "Services reports not yet logged in.\n");
			$logged_in = 0;
			&services_login($kernel);
		}
	}
}

# REQUEST_UNBAN: If the bot is out of the channel, request an unban
# from ChanServ.
sub request_unban {
    my ($kernel, undef, $channel, undef, $msg) = @_;
    if (&SimBot::option('services', 'pass')) {
		$locked_out = 1;
		if($services_online && $logged_in) {
			if ($msg =~ /banned/i) {
				&SimBot::debug(2, "Could not join.  Asking services for unban from $channel...\n");
				$kernel->post(bot => sl => "chanserv unban $channel");
			} else { # Try Invite
				&SimBot::debug(2, "Could not join.  Asking services for invite to $channel...\n");
				$kernel->post(bot => sl => "chanserv invite $channel");
			}
		} elsif ($services_online) {
			&services_login($kernel);
		}
	}
}

# REQUEST_VOICE: If the bot was not able to speak, request a voice from ChanServ.
sub request_voice {
    my ($kernel, undef, $channel) = @_;
    if (&SimBot::option('services', 'pass')) {
		$shut_up = 1;
		if($services_online && $logged_in) {
			&SimBot::debug(2, "Could not speak.  Asking for voice on $channel...\n");
			$kernel->post(bot => sl => "chanserv voice $channel");
			$shut_up = 0;
		} elsif ($services_online) {
			&services_login($kernel);
		}
    }
}

# PROCESS_JOIN: Upon joining the channel, it's clear we're no longer locked
# out of it.
sub process_join {
    my ($kernel, $nick, $channel) = @_;
    $locked_out = 0;
}

# PROCESS_NOTIFY: Check to see if nickserv is online, and if not previously
# online, log in.  Also log in if we're waiting for nickserv and detect that
# services are available.
sub process_notify {
    my ($kernel, undef, undef, @nicks) = @_;
    my $found = 0;
 	my $me   = $SimBot::chosen_nick;
	my $want = &SimBot::option('global', 'nickname');
	my $pass = &SimBot::option('services', 'pass');

    foreach(@nicks) {
		if($_ eq "NickServ") {
			$found = 1;
		}
    }

	if ((!$services_online) && $found) {
		if ($me eq $want) {
			# Just check registration.  Nickserv will let us know whether
			# we need to log in.
			# XXX: This should probably be delayed.
			&registration_check($kernel, undef, undef, $me);
		} else {
			&SimBot::debug(3, "Desired nickname is in use; trying ghost...\n");
			$kernel->post(bot => sl => "nickserv ghost $want $pass");
		}
	}
    $services_online = $found;
}

# KICK_USER: Kicks a user through ChanServ.
sub kick_user {
    my ($kernel, $channel, $user, $message) = @_;
	&SimBot::debug(3, "Asking Channel Service to kick $user from $channel ($message)...\n");
	$kernel->post(bot => sl => "chanserv kick $channel $user $message");
}

# BAN_USER: Kickbans a user through ChanServ.
sub ban_user {
    my ($kernel, $channel, $user, $time, $message) = @_;
	my $hours = int($time / 3600);
	&SimBot::debug(3, "Asking Channel Service to ban $user (" .
				   &SimBot::hostmask($user) .
				   ") from $channel ($message)...\n");
	$kernel->post(bot => sl => "chanserv ban $channel " . &SimBot::hostmask($user) . "$message");
}

# XXX: Freenode, at least, you can't unban specific users, it appears.

# UNBAN_USER: Unbans a user through ChanServ.
#sub unban_user {
#    my (undef, $channel, $user, $message) = @_;
#        &SimBot::debug(3, "Asking Channel Service to unban $user (" .
#					   &SimBot::hostmask($user) .
#					   ") from $channel...\n");
#	&SimBot::send_message("ChanServ", "unban $channel " . &SimBot::hostmask($user));
#}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "services::chanserv",
						 event_server_ison     => \&process_notify,
						 event_private_notice  => \&check_response,
						 event_channel_nojoin  => \&request_unban,
						 event_channel_mejoin  => \&process_join,
						 event_channel_novoice => \&request_voice,
						 event_server_nick     => \&registration_check,

						 list_nicks_ison       => "NickServ",
						 );

# Override Default Command Operations
$SimBot::commands{kick}  = \&kick_user;
$SimBot::commands{ban}   = \&ban_user;
