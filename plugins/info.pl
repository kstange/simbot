# SimBot Recap Plugin
#
# Copyright (C) 2004, Pete Pearson
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

package SimBot::plugin::info;

use warnings;

sub messup_info {
    dbmopen(%isDB, 'is', 0664);
    dbmopen(%areDB, 'are', 0664);
}

sub cleanup_info {
    dbmclose(%isDB); dbmclose(%areDB);
}

sub learn_info {
    my($kernel, $nick, $channel, $doing, $content, $being_addressed) = @_;
    my($person_being_referenced);
    
    if($content =~ m/^.info/) { return; }
    
    # Is someone being referenced?
    if($content =~ s{, (\S*)$}{}) { # whatever, JohnDoe
        $person_being_referenced = $1;
    }
    if($content =~ s{^(\S*)[:,] }{}) { # JohnDoe: whatever
        $person_being_referenced = $1;
    }
    if($being_addressed) {
        $person_being_referenced = $SimBot::nickname;
    }
    
    $content = &munge_pronouns($content, $nick, $person_being_referenced);
    
    if($content =~ m{(.*(but|and|however|;|:|,|\.) *)?(.*) is.*((http|ftp|mailto|news|nntp)s?://\S*)}ig) {
        # looks like a URL to me!
        my ($key, $factoid) = (lc($3), $4);
        $factoid = 'at ' . $factoid;
        unless($isDB{$key}) {
            $isDB{$key} = $factoid;
            &report_learned($channel, $nick, $key, 'is', $factoid, $being_addressed);
        }
    } elsif($content =~ m{([\w\s]+?) (is|are) ([\w\s]+)}) {
        my ($key, $isare, $factoid) = (lc($1), $2, $3);

        foreach(@SimBot::chat_ignore) {
            if($content =~ /$_/) {
                &SimBot::send_message($channel, "I cannot do that, $nick.") if $being_addressed;
                return;
            }
        }
        
        if($key =~ m/(your|you're|you are)/) {
            # key contains a pronoun we can't expand
            # Let's not learn it.
            return;
        }
        if($isare =~ m/is/g) {
            if($isDB{$key}) {
                
            } else {
                $isDB{$key} = $factoid;
                &report_learned($channel, $nick, $key, 'is', $factoid, $being_addressed);
            }
        } else {
            unless($areDB{$key}) {
                $areDB{$key} = $factoid;
                &report_learned($channel, $nick, $key, 'are', $factoid, $being_addressed);
            }
        }
    }
}

sub get_info {
    my($kernel, $nick, $channel, undef, @query) = @_;

    $query = &munge_pronouns(join(' ', @query), $nick, $SimBot::nickname);

    if($query =~ m{^forget (.*)}) {
        # looks like someone wants us to be forgetful
        my($forgotten, $key) = (0, lc($1));
        if($isDB{$key}) {
            undef $isDB{$key};
            $forgotten = 1;
        }
        if($areDB{$key}) {
            undef $areDB{$key};
            $forgotten = 1;
        }
        if($forgotten) {
            &SimBot::debug(3, "Forgot $key (req'd by $nick)\n");
            &SimBot::send_message($channel, "$nick: OK, I forgot $key.");
        } else {
            &SimBot::send_message($channel, "$nick: I don't know $key!");
        }
    } elsif($query =~ m{ (is|are) }) {
        #looks like someone's teaching
        # my($kernel, $nick, $channel, $doing, $content, $being_addressed)
        &learn_info(undef, $nick, $channel, undef, $query, 1);
    } else {
        #looks like someone wants to learn
        $query = lc($query);
        if($isDB{$query}) {
            if($isDB{$query} =~ m/<reply>(.*)/) {
                &SimBot::send_message($channel, $1);
            } else {
                &SimBot::send_message($channel, "$nick: I believe $query is $isDB{$query}.");
            }
        } elsif($areDB{$query}) {
            &SimBot::send_message($channel, "$nick: I believe $query are $areDB{$query}.");
        } else {
            &SimBot::send_message($channel, "$nick: I don't know.");
        }
    }
}

sub report_learned {
    my($channel, $nick, $key, $isare, $factoid, $addressed) = @_;
    &SimBot::debug(3, "Learning from $nick: $key =$isare=> $factoid\n");
    &SimBot::send_message($channel, "$nick: OK. ($key =$isare=> $factoid)") if $addressed;
}

sub munge_pronouns {
    my ($content, $nick, $person_being_referenced, $thirdperson) = @_;
    
    $content =~ s/(^|\s)i am /$1$nick is /ig;
    $content =~ s/(^|\s)my /$1${nick}'s /ig;
    if($person_being_referenced) {
        $content =~ s/(^|\s)(you're|you are) /$1${person_being_referenced} is /ig;
        $content =~ s/(^|\s)your /$1${person_being_referenced}'s /ig;
    }
    
    return $content;
}

&SimBot::plugin_register(
    plugin_id   => 'info',
    plugin_desc => 'Tells you what simbot has learned about something.',
    event_plugin_call   => 'get_info',
    event_plugin_load   => 'messup_info',
    event_plugin_unload => 'cleanup_info',
    event_channel_message   => 'learn_info',
);