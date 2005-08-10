# SimBot Recap Plugin
#
# Copyright (C) 2003-05, Kevin Stange <kevin@simguy.net>
#
# This program is free software; you can redistribute and/or modify it
# under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
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

use constant MAX_BACKLOG => 30;
use constant STD_BACKLOG => 10;

our @backlog = ();
our %departs = ();

# SEND_RECAP: Sends a backlog of chat to the inquiring user.
sub send_recap {
    my ($kernel, $nick, $channel, undef, $lines) = @_;
	if (!defined $lines) {
		if (defined $departs{$nick}) {
			$lines = $departs{$nick};
			&SimBot::debug(4, "recap: $nick recently departed, recapping from departure point ($lines lines)...\n");
		} else {
			$lines = STD_BACKLOG;
			&SimBot::debug(4, "recap: $nick did not specify number of lines; using default ($lines lines)...\n");
		}
	}

    &SimBot::debug(3, "recap: Got a request from $nick for $lines lines. The backlog is " . ($#backlog + 1) . " lines.\n");
    if (defined $lines && $lines =~ /^[^0-9]+$/) {
		&SimBot::send_message($channel, "Try using numbers.  I can't count to $lines!");
	} elsif ($#backlog + 1 < 1) {
		&SimBot::send_notice($nick, "I haven't seen enough chat yet to provide a useful recap.");
	} elsif (defined $lines && $lines < 0) {
		&SimBot::send_message($channel, "$nick: Sorry, I haven't figured out how to precap yet.");
	} elsif (defined $lines && $lines == 0) {
		&SimBot::send_message($channel, "$nick: Nothing has happened since the last time something happened.");
	} elsif (defined $lines && ($lines > MAX_BACKLOG)) {
		&SimBot::send_notice($nick, "I can only display between 1 and " . MAX_BACKLOG . " lines of recap.");
	} else {
		if ($#backlog < $lines) {
			&SimBot::send_notice($nick, "Note: I have not seen as many lines of chat as you requested.  I'll show you everything I've got.");
			$lines = $#backlog;
		}
		&SimBot::send_pieces_with_notice($nick, undef, join("\n", @backlog[(($#backlog)-$lines) .. ($#backlog-1)]));
	}
}

# RECORD_RECAP: Puts stuff in the backlog!
sub record_recap {
    my($kernel, $nick, $channel, $doing, $content, $target) = @_;
	my(@args) = @_[ 4 .. $#_ ];
    my ($sec, $min, $hour) = localtime(time);
	foreach my $departed (keys %departs) {
		if ($departs{$departed} == MAX_BACKLOG) {
			&SimBot::debug(4, "recap: $departed is no longer recently departed.\n");
			delete $departs{$departed};
		} else {
			$departs{$departed}++;
		}
	}
    my $line = sprintf("[%02d:%02d:%02d] ", $hour, $min, $sec);
    if ($doing eq 'SAY') {
		$line .= "<$nick> $content";
    } elsif ($doing eq 'ACTION') {
		$line .= "* $content";
    } elsif ($doing eq 'KICKED') {
		$line .= "$target kicked $nick from $channel" . ($content ? " ($content)" : "");
		$departs{$nick} = 0;
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
		$departs{$nick} = 0;
	} elsif ($doing eq 'QUIT') {
		$line .= "$nick has quit IRC" . ($content ? " ($content)" : "");
		$departs{$nick} = 0;
	} elsif ($doing eq 'NICK') {
		$line .= "$nick is now known as $target";
	}
    push(@backlog, $line);
    while ($#backlog > MAX_BACKLOG) {
		shift(@backlog);
    }
    &SimBot::debug(4, "recap: Recorded a line. Backlog is " . ($#backlog + 1) . " lines.\n");
}

sub nick_change {
    my($kernel, undef, $nick, $newnick) = @_;
	record_recap($kernel, $nick, undef, "NICK", undef, $newnick);
}

sub recap_page {
    my ($request, $response, $get_template) = @_;
    
#    $response->code(RC_OK);
    $response->push_header("Content-Type", "text/html");
    my $template = &$get_template('base');
    $template->param(
        title => 'Recent Chatter',
        content => &SimBot::htmlize(join("\n", @backlog)),
    );
    $response->content($template->output());
    return 200;
}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "recap",
						 plugin_params => "[<lines>]",
						 plugin_help => "Privately recaps up to " . MAX_BACKLOG
						 . " lines of chat backlog. The default is to recap " .
						 STD_BACKLOG . " lines or from the point the user " .
						 "last departed.",
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

$SimBot::hash_plugin_httpd_pages{'recap'} = {
    'title' => "Current Chatter",
    'handler' => \&recap_page,
}
