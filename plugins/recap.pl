# SimBot Recap Plugin
#
# Copyright (C) 2003-04, Kevin Stange <kevin@simguy.net>
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

package SimBot::plugin::recap;

use strict;
use warnings;

our @backlog = ();
our $max_backlog = 30;
our $std_backlog = 10;

# SEND_RECAP: Sends a backlog of chat to the inquiring user.
sub send_recap {
    my ($kernel, $nick, $channel, undef, $lines) = @_;
    &SimBot::debug(3, "Received recap command from $nick... backlog is " . $#backlog . " lines, user wants " . (defined $lines ? $lines : $std_backlog) ." lines.\n");
    if ($#backlog + 1 < 1) {
		&SimBot::send_notice($nick, "I haven't seen enough chat yet to provide a useful recap.");
	} elsif (defined $lines && ($lines < 1 || $lines > $max_backlog)) {
		&SimBot::send_notice($nick, "I can only display between 1 and $max_backlog lines of recap.");
	} else {
		if (!defined $lines) {
			$lines = $std_backlog;
		}
		if ($#backlog < $lines) {
			&SimBot::send_notice($nick, "Note: I have not seen as many lines of chat as you requested.  I'll show you everything I've got.");
			$lines = $#backlog;
		}
		for(my $i=($#backlog)-$lines; $i < $#backlog; $i++) {
			&SimBot::send_notice($nick, $backlog[$i]);
		}
	}
}

# RECORD_RECAP: Puts stuff in the backlog!
sub record_recap {
    my($kernel, $nick, $channel, $doing, $content, $target) = @_;
	my(@args) = @_[ 4 .. $#_ ];
    my ($sec, $min, $hour) = localtime(time);
    my $line = sprintf("[%02d:%02d:%02d] ", $hour, $min, $sec);
    if ($doing eq 'SAY') {
		$line .= "<$nick> $content";
    } elsif ($doing eq 'ACTION') {
		$line .= "* $nick $content";
    } elsif ($doing eq 'KICKED') {
		$line .= "$target kicked $nick from $channel" . ($content ? " ($content)" : "");
    } elsif ($doing eq 'TOPIC') {
		if ($content) {
			$line .= "$nick changed the topic of $channel to: $content";
		} else {
			$line .= "$nick unset the topic of $channel.";
		}
    } elsif ($doing eq 'MODE') {
		$line .= "$nick set modes [@args] on $channel";
	} elsif ($doing eq 'JOINED') {
		$line .= "$nick has joined $channel";
	} elsif ($doing eq 'PARTED') {
		$line .= "$nick has left $channel" . ($content ? " ($content)" : "");
	} elsif ($doing eq 'QUIT') {
		$line .= "$nick has quit IRC" . ($content ? " ($content)" : "");
	} elsif ($doing eq 'NICK') {
		$line .= "$nick is now known as $target";
	}
    push(@backlog, $line);
    while ($#backlog > $max_backlog) {
		shift(@backlog);
    }
    &SimBot::debug(4, "Recorded a line for recap... backlog is " . $#backlog . " lines.\n");
}

sub nick_change {
    my($kernel, undef, $nick, $newnick) = @_;
	record_recap($kernel, $nick, undef, "NICK", undef, $newnick);
}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "recap",
						 plugin_desc => "Privately recaps up to $max_backlog lines of chat backlog. The default is to recap $std_backlog lines.",
						 event_plugin_call         => \&send_recap,
						 event_channel_kick        => \&record_recap,
						 event_channel_message     => \&record_recap,
						 event_channel_message_out => \&record_recap,
						 event_channel_action      => \&record_recap,
						 event_channel_action_out  => \&record_recap,
						 event_channel_topic       => \&record_recap,
						 event_channel_mode        => \&record_recap,
						 event_channel_quit        => \&record_recap,
						 event_channel_join        => \&record_recap,
						 event_channel_mejoin      => \&record_recap,
						 event_channel_part        => \&record_recap,
						 event_server_nick         => \&nick_change,
						 );
