# SimBot Seen Plugin
#
# Copyright (C) 2003, Pete Pearson
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

package SimBot::plugin::seen;

# MESSUP_SEEN: Opens the seen database for use
sub messup_seen {
    SimBot::debug(3, "Loading seen database...\n");
    dbmopen (%seenData, 'seen', 0664) || return 0;
}

# GET_SEEN: Checks to see if a person has done anything lately...
sub get_seen {
    my ($kernel, $nick, $channel, undef, $person) = @_;
    if(!$person) {
        $kernel->post(bot => privmsg => $channel, "$nick: There are many things I have seen. Perhaps you should ask for someone in particular?");
    } elsif(lc($person) eq lc($chosen_nick)) {
        $kernel->post(bot => ctcp => $channel, 'ACTION', "waves $hisher hand in front of $hisher face. \"Yup, I can see myself!\"");
    } elsif($seenData{lc($person)}) {
        my ($when, $doing, $seenData) = split(/!/, $seenData{lc($person)}, 3);
        $doing = "saying \"$seenData\"" if($doing eq 'SAY');
        $doing = 'in a private message' if($doing eq 'PMSG');
        $doing = "($seenData)" if ($doing eq 'ACTION');
        if($doing eq 'KICKED') {
            my ($kicker,$reason) = split(/!/, $seenData, 2);
            $doing = "getting kicked by $kicker ($reason)";
        }
        if($doing eq 'KICKING') {
            my ($kicked,$reason) = split(/!/, $seenData, 2);
            $doing = "kicking $kicked ($reason)";
        }
        my $response = "I last saw $person " . SimBot::timeago($when) . " ${doing}.";
        $kernel->post(bot => privmsg => $channel, "$nick: $response");
    } else {
        $kernel->post(bot => privmsg => $channel, "$nick: I have not seen $person.");
    }
}

# SET_SEEN: Updates seen data
sub set_seen {
    my($kernel, $nick, $channel, $doing, $content, $target) = @_;
    SimBot::debug(4, "Seeing $nick ($doing $content)\n");
    my $time = time;
    $seenData{lc($nick)} = "$time!$doing!" . ($target ? "$target!" : "") . "!$content";
    
    if($doing eq 'KICKED') {
        $doing = 'KICKING';
        $seenData{lc($target)} = "$time!$doing!$nick!$reason";
        SimBot::debug(4, "Seeing $target ($doing $nick!$reason)\n");
    }
}

# CLEANUP_SEEN: Cleans up when we're quitting
sub cleanup_seen {
    SimBot::debug(3, "Saving seen data\n");
    dbmclose(%seenData);
}

# Register Plugin
SimBot::plugin_register(plugin_id   => "seen",
			plugin_desc => "Tells you the last time I saw someone.",
			event_plugin_call     => "get_seen",
			event_plugin_load     => "messup_seen",
			event_plugin_unload   => "cleanup_seen",
			event_channel_kick    => "set_seen",
			event_channel_public  => "set_seen",
			event_channel_action  => "set_seen",
			);
