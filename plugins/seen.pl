# SimBot Seen Plugin
#
# Copyright (C) 2003-04, Pete Pearson
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
use warnings;

# MESSUP_SEEN: Opens the seen database for use
sub messup_seen {
    &SimBot::debug(3, "Loading seen database...\n");
    dbmopen (%seenData, 'seen', 0664) || return 0;
}

# GET_SEEN: Checks to see if a person has done anything lately...
sub get_seen {
    my ($kernel, $nick, $channel, undef, $person) = @_;
    if(!$person) {
        &SimBot::send_message($channel,
            "$nick: There are many things I have seen. Perhaps you should ask for someone in particular?");
    } elsif(lc($person) eq lc($SimBot::chosen_nick)) {
        &SimBot::send_action($channel,
                qq(waves $SimBot::hisher hand in front of $SimBot::hisher face. "Yup, I can see myself!"));

    } elsif($seenData{lc($person)}) {
        my ($when, $doing, $seenData) = split(/!/, $seenData{lc($person)}, 3);

        if   ($doing eq 'SAY')      { $doing = qq(saying "$seenData");              }
        elsif($doing eq 'NOTICE')   { $doing = qq(saying "$seenData" in a notice);  }
        elsif($doing eq 'PRIVMSG')  { $doing = 'in a private message';              }
        elsif($doing eq 'ACTION')   { $doing = "($seenData)";                       }
        elsif($doing eq 'TOPIC')
            { $doing = qq(changing the topic to "$seenData"); }

        elsif($doing eq 'KICKED') {
            my ($kicker,$reason) = split(/!/, $seenData, 2);
            $doing = "getting kicked by $kicker ($reason)";
        }
        elsif($doing eq 'KICKING') {
            my ($kicked,$reason) = split(/!/, $seenData, 2);
            $doing = "kicking $kicked ($reason)";
        }

        my $response = "I last saw $person " . SimBot::timeago($when) . " ${doing}.";
        &SimBot::send_message($channel, "$nick: $response");
    } else {
        &SimBot::send_message($channel, "$nick: I have not seen $person.");
    }
}

# SET_SEEN: Updates seen data
sub set_seen {
    my($kernel, $nick, $channel, $doing, $content, $target) = @_;
    SimBot::debug(4, "Seeing $nick ($doing $content)\n");
    my $time = time;
    $seenData{lc($nick)} = "$time!$doing!" . ($target ? "$target!" : "")
                            . "$content";

    if($doing eq 'KICKED') {
        $doing = 'KICKING';
        $seenData{lc($target)} = "$time!$doing!$nick!$content";
        SimBot::debug(4, "Seeing $target ($doing $nick!$content)\n");
    }
}

# SCORE_WORD: Gives a score modifier to a word
# for seen, we give a 40 point bonus to words that are the
# nicknames of people we have seen.
sub score_word {
    if (defined $seenData{$_[1]}) {
	&SimBot::debug(3, "$_[1]:+1000(seen) ");
	return 1000;
    }
    &SimBot::debug(4, "$_[1]:+0(seen) ");
    return 0;
}

# CLEANUP_SEEN: Cleans up when we're quitting
sub cleanup_seen {
    &SimBot::debug(3, "Saving seen data\n");
    dbmclose(%seenData);
}

# Register Plugin
&SimBot::plugin_register(plugin_id   => "seen",
						 plugin_desc => "Tells you the last time I saw someone.",
						 event_plugin_call     => \&get_seen,
						 event_plugin_load     => \&messup_seen,
						 event_plugin_unload   => \&cleanup_seen,
						 event_channel_kick    => \&set_seen,
						 event_channel_message => \&set_seen,
						 event_channel_action  => \&set_seen,
						 event_channel_topic   => \&set_seen,
						 event_channel_notice  => \&set_seen,
						 query_word_score      => \&score_word,
						 );
