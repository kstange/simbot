# SimBot Undernet Services Plugin
#
# Copyright (C) 2003, Kevin Stange
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

package SimBot::plugin::services::undernet;

# Start with the assumption X is online, we are not locked out, and
# we are not logged in, and we are not shut up.
$x_online   = 1;
$logged_in  = 0;
$locked_out = 0;
$shut_up    = 0;

# SERVICES_LOGIN: Here, we log into X if we have a services username and
# password, since logging in would be tricky, at best, without them.
# We also set the +x mode to mask our hostname for some added security.
sub services_login {
    my ($kernel, undef, $nick) = @_;
    if (defined $nick) {
	&SimBot::debug(3, "Setting masked user mode...\n");
	$kernel->call(bot => mode => $nick, "+x");
    }
    if ($SimBot::services_pass && $SimBot::services_user) {
	&SimBot::debug(3, "Logging into Channel Service as $SimBot::services_user...\n");
	$kernel->call(bot => privmsg => "x\@channels.undernet.org", "login $SimBot::services_user $SimBot::services_pass");
    }
}

# CHECK_RESPONSE: When we try to log in or run a command, X will tell us
# something.  Here, we handle different possible cases.
sub check_response {
    my ($kernel, $nick, undef, $text) = @_;
    if ($nick eq "X") {
	if ($text =~ /AUTHENTICATION SUCCESSFUL as /) {
	    &SimBot::debug(3, "Channel Service reports successful login.\n");
	    $logged_in = 1;
	    $x_online = 1;
	    if ($locked_out) {
		&request_invite($kernel, undef, $SimBot::channel);
	    }
	    if ($shut_up) {
		&request_voice($kernel, undef, $SimBot::channel);
	    }
	} elsif ($text =~ /AUTHENTICATION FAILED as /) {
	    &SimBot::debug(2, "Channel Service reports login failure.\n");
	    $logged_in = 0;
	    $x_online = 1;
	} elsif ($text =~ /Sorry, You are already authenticated as /) {
	    &SimBot::debug(2, "Channel Service reports already logged in.\n");
	    $logged_in = 1;
	    $x_online = 1;
	} elsif ($text =~ /Sorry, You must be logged in to /) {
	    &SimBot::debug(2, "Channel Service reports not yet logged in.\n");
	    $logged_in = 0;
	    $x_online = 1;
	    &services_login($kernel);
	} else {
	    &SimBot::debug(4, "Channel Service message: $text\n");
	}
    }
}

# REQUEST_INVITE: If the bot is out of the channel, request an invitation
# from X.
sub request_invite {
    my ($kernel, undef, $channel) = @_;
    if ($SimBot::services_pass) {
	$locked_out = 1;
	if($x_online && $logged_in) {
	    &SimBot::debug(2, "Could not join.  Asking for invitation to $channel...\n");
	    $kernel->post(bot => privmsg => "x", "invite $channel");
	} elsif ($x_online) {
	    &services_login($kernel);
	}
    }
}

# REQUEST_VOICE: If the bot was not able to speak, request a voice from X.
sub request_voice {
    my ($kernel, undef, $channel) = @_;
    if ($SimBot::services_pass) {
	$shut_up = 1;
	if($x_online && $logged_in) {
	    &SimBot::debug(2, "Could not speak.  Asking for voice on $channel...\n");
	    $kernel->post(bot => privmsg => "x", "voice $channel");
	    $shut_up = 0;
	} elsif ($x_online) {
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

# PROCESS_NOTIFY: Check to see if X is online, and if not previously online,
# log in.  Also log in if we're waiting for X and detect that X is available.
sub process_notify {
    my ($kernel, undef, undef, @nicks) = @_;
    my $found = 0;
    foreach(@nicks) {
	if($_ eq "X") {
	    $found = 1;
	}
    }
    if ((!$x_online || $locked_out || $shut_up) && $found) {
	&services_login($kernel);
    }
    $x_online = $found;
}

# Register Plugin
SimBot::plugin_register(plugin_id   => "services::undernet",
			event_server_connect  => "services_login",
			event_server_ison     => "process_notify",
			event_private_notice  => "check_response",
			event_channel_nojoin  => "request_invite",
			event_channel_mejoin  => "process_join",
			event_channel_novoice => "request_voice",

			list_nicks_ison       => "X",
			);
