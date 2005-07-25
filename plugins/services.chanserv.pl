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
#       testing and feedback from other networks are needed and welcome.

package SimBot::plugin::services::chanserv;

use warnings;
use strict;

# Start with the assumption Services are online, we are not locked out, and
# we are not logged in, and we are not shut up.
our $services_online = 1;
our $logged_in       = 0;
our $locked_out      = 0;
our $shut_up         = 0;

# SERVICES_LOGIN: Here, we log into nickserv if we have a services username and
# password, since logging in would be tricky, at best, without them.
sub services_login {
    my ($kernel) = @_;
	my $pass = &SimBot::option('services', 'pass');

    if ($pass) {
		&SimBot::debug(3, "Logging into services...\n");
		&SimBot::send_message("nickserv", "identify $pass");
    }
}

# CHECK_RESPONSE: When we try to log in or run a command, services will tell us
# something.  Here, we handle different possible cases.
sub check_response {
    my ($kernel, $nick, undef, $text) = @_;
	my $user = &SimBot::option('services', 'user');
	my $pass = &SimBot::option('services', 'pass');
	my $me   = $SimBot::chosen_nick;
	my $chan = &SimBot::option('network', 'channel');
    if (lc($nick) eq lc("NickServ")) {
		$services_online = 1;

		if ($text =~ /is( not|n\'t) registered/i) {
			# Try to register!!
			&SimBot::debug(2, "Nickname $me is not registered; Trying to register it now...\n");
			&SimBot::send_message("nickserv", "register $pass");
		} elsif ($text =~ /Your nickname is now registered/i) {
			&SimBot::debug(3, "Nickname $me registered successfully.\n");
			$logged_in = 1;
			# Special case.  If username is set, link this nickname to main.
			if (defined $user && lc($me) ne lc($user)) {
				&SimBot::debug(3, "Attempting to link nickname registration to $user...\n");
				&SimBot::send_message("nickserv", "link $user $pass");
			}
			if ($locked_out) {
				&request_unban($kernel, undef, $chan);
			}
			if ($shut_up) {
				&request_voice($kernel, undef, $chan);
			}
		} elsif ($text =~ /Your nickname is now linked/i) {
			&SimBot::debug(3, "Nickname linked to $user successfully.\n");
		} elsif ($text =~ /Password incorrect/i) {
			if ($logged_in == 0) {
                &SimBot::debug(1, "Services reports login failure.\n");
			} else {
				&SimBot::debug(1, "Services command failed: Incorrect password.\n");
			}
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
				&SimBot::send_message("ChanServ", "unban $channel");
			} else { # Try Invite
				&SimBot::debug(2, "Could not join.  Asking services for invite to $channel...\n");
				&SimBot::send_message("ChanServ", "invite $channel");
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
			&SimBot::send_message("ChanServ", "voice $channel");
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
    foreach(@nicks) {
		if($_ eq "NickServ") {
			$found = 1;
		}
    }
    if ((!$services_online || $locked_out || $shut_up) && $found) {
		&services_login($kernel);
    }
    $services_online = $found;
}

# KICK_USER: Kicks a user through ChanServ.
sub kick_user {
    my (undef, $channel, $user, $message) = @_;
	&SimBot::debug(3, "Asking Channel Service to kick $user from $channel ($message)...\n");
	&SimBot::send_message("ChanServ", "kick $channel $user $message");
}

# BAN_USER: Kickbans a user through ChanServ.
sub ban_user {
    my (undef, $channel, $user, $time, $message) = @_;
        my $hours = int($time / 3600);
        &SimBot::debug(3, "Asking Channel Service to ban $user (" .
                                   &SimBot::hostmask($user) .
                                   ") from $channel ($message)...\n");
        &SimBot::send_message("ChanServ", "ban $channel " . &SimBot::hostmask($user) . "$message");
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

# XXX: This needs to be very smart or go away.

# MASK_USERHOST: Checks to see if a special network-related hostmasking is
# in place and ensures it is generalized properly.
#sub mask_userhost {
#    my ($user, $host) = split(/@/, $_[1]);
#        if ($host =~ /\.users\.undernet\.org$/) {
#                return "*\@$host";
#        } else {
#                return undef;
#        }
#}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "services::chanserv",
						 event_server_connect  => \&services_login,
						 event_server_ison     => \&process_notify,
						 event_private_notice  => \&check_response,
						 event_channel_nojoin  => \&request_unban,
						 event_channel_mejoin  => \&process_join,
						 event_channel_novoice => \&request_voice,

# TODO						 query_userhost_mask   => \&mask_userhost,

						 list_nicks_ison       => "NickServ",
						 );

# Override Default Command Operations
$SimBot::commands{kick}  = \&kick_user;
$SimBot::commands{ban}   = \&ban_user;
