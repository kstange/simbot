# SimBot Info Plugin
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
use constant I_DONT_KNOW =>
    ('$nick: Damned if I know!', '$nick: Huh?', 'I dunno, $nick.',
     'Tell me if you find out, $nick.', );
use constant OK_LEARNED =>
    ('$nick: I will remember that.', 'OK, $nick.',
     'I\'ll keep that in mind, $nick.', );
use constant OK_FORGOTTEN =>
    ('$nick: What were we talking about again?',
	 '$nick: Information has been nullified!  Have a nice day.',
	 '$nick: Done.  Wouldn\'t it be cool if %uline%you%uline% could forget on demand?',
	 );
use constant CANT_FORGET =>
    ('$nick: I don\'t know anything about $key.');
use constant QUERY_RESPONSE =>
    ('$nick: I have been told that $key $isare $factoid.',
     '$nick: Someone mentioned that $key $isare $factoid.',
     '$nick: $key, according to popular belief, $isare $factoid.',
    );
use constant ALREADY_WAS =>
    ('I already know that, $nick.');
use constant BUT_X_IS_Y =>
    ('$nick: I thought $key $isare $factoid.');
use constant I_CANNOT =>
    ('I cannot do that, $nick.');
     
sub messup_info {
    dbmopen(%isDB, 'is', 0664);
    dbmopen(%areDB, 'are', 0664);
}

sub cleanup_info {
    dbmclose(%isDB); dbmclose(%areDB);
}

sub learn_info {
    my($kernel, $nick, $channel, $doing, $content) = @_;
    my($person_being_referenced, $being_addressed, $is_query); 
    
    if($content =~ s/^.info ?//) {
        $being_addressed = 1;
    }
    
    # Is someone being referenced?
    if($content =~ s{, (\S*)[.\!\?]?$}{}) { # whatever, JohnDoe
        $person_being_referenced = $1;
    }
    if($content =~ s{^(\S*)[:,] }{}) {      # JohnDoe: whatever
        $person_being_referenced = $1;
    }
    if($being_addressed) {
        $person_being_referenced = $SimBot::nickname;
#    } elsif($person_being_addressed =~ m/$SimBot::nickname/g) {
#        $being_addressed = 1;
    }
    
    $content = &munge_pronouns($content, $nick, $person_being_referenced);
    $content = &normalize_urls($content);
    
    if($being_addressed && $content =~ m{^forget ([\w\s]+)}i) {
        # someone wants us to forget
        
        my($forgotten, $key) = (0, lc($1));
        if($isDB{$key}) {
            delete $isDB{$key};
            $forgotten = 1;
        }
        if($areDB{$key}) {
            delete $areDB{$key};
            $forgotten = 1;
        }
        if($forgotten) {
            &SimBot::debug(3, "Forgot $key (req'd by $nick)\n");
            &SimBot::send_message($channel,
                &parse_message(&SimBot::pick(OK_FORGOTTEN),
                               $nick, $key));
        } else {
            &SimBot::send_message($channel,
                &parse_message(&SimBot::pick(CANT_FORGET),
                               $nick, $key));
        }
    } elsif($content =~ m{(where|what|who) is ([\'\w\s]+)}i) {
        # looks like a query
        &handle_query($2, $nick, $channel, $person_being_referenced,
                      $being_addressed);
    } elsif($content =~ m{([\'\w\s]+) is[\s\w]* (\w+://\S+)}i) {
        # looks like a URL to me!
        my ($key, $factoid) = (lc($1), $2);
        $factoid = 'at ' . $factoid;
        unless($isDB{$key}) {
            $isDB{$key} = $factoid;
            &report_learned($channel, $nick, $key, 'is', $factoid, $being_addressed);
        }
    } elsif($content =~ m{([\'\w\s]+?) (is|are) ([\'\w\s]+)}i) {
        my ($key, $isare, $factoid) = (lc($1), $2, $3);

        foreach(@SimBot::chat_ignore) {
            if($content =~ /$_/) {
                &SimBot::send_message($channel, "I cannot do that, $nick.") if $being_addressed;
                return;
            }
        }
        
        if($key =~ m/(your|you're|you are)/i) {
            # key contains a pronoun we can't expand
            # Let's not learn it.
            return;
        }
        if($isare =~ m/is/i) {
            if($isDB{$key}) {
                &SimBot::send_message($channel, "$nick: But $key is $isDB{$key}.") if $being_addressed;
            } else {
                $isDB{$key} = $factoid;
                &report_learned($channel, $nick, $key, 'is', $factoid, $being_addressed);
            }
        } else {
            if($areDB{$key}) {
                &SimBot::send_message($channel, "$nick: But $key are $isDB{$key}.") if $being_addressed;
            } else {
                $areDB{$key} = $factoid;
                &report_learned($channel, $nick, $key, 'are', $factoid, $being_addressed);
            }
        }
    } elsif($being_addressed && $content =~ m{^([\'\w\s]+)$}) {
        # KEEP THIS ELSIF LAST
        # Single phrase, doesn't match anything else and we are being
        # addressed. Let's do a query.
        &handle_query($1, $nick, $channel, $person_being_referenced,
                      $being_addressed);
    }
}

sub handle_query {
    my ($query, $nick, $channel, $person_being_addressed, $being_addressed)
        = @_;
    
    if($person_being_addressed && !$being_addressed) {
        # Someone's being referenced, and it isn't us
        # We should keep quiet.
        return;
    }
    
    $query = lc($query);
    if($isDB{$query}) {
        &SimBot::send_message($channel,
                    &parse_message(&SimBot::pick(QUERY_RESPONSE),
                                   $nick, $query, 'is', $isDB{$query}));
    } elsif($areDB{$query}) {
        &SimBot::send_message($channel,
                    &parse_message(&SimBot::pick(QUERY_RESPONSE),
                                   $nick, $query, 'are', $isDB{$query}));
    } elsif($being_addressed) {
        # we're being addressed, but don't have an answer...
        &SimBot::send_message($channel,
            &parse_message(&SimBot::pick(I_DONT_KNOW),
                           $nick, $query));
    }
}

sub report_learned {
    my($channel, $nick, $key, $isare, $factoid, $addressed) = @_;
    &SimBot::debug(3, "Learning from $nick: $key =$isare=> $factoid\n");
    &SimBot::send_message($channel, &parse_message(&SimBot::pick(OK_LEARNED), $nick) . " ($key =$isare=> $factoid)") if $addressed;
}

sub parse_message {
    my ($message, $nick, $key, $isare, $factoid) = @_;
    
    $message = &SimBot::parse_style($message);
    
    $message =~ s/\$nick/$nick/;
    $message =~ s/\$key/$key/;
    $message =~ s/\$isare/$isare/;
    $message =~ s/\$factoid/$factoid/;
    
    return $message;
}

sub munge_pronouns {
    my ($content, $nick, $person_being_referenced, $thirdperson) = @_;
    
    $content =~ s/(^|\s)i am /$1$nick is /ig;
    $content =~ s/(^|\s)my /$1${nick}'s /ig;
    if($person_being_referenced) {
        $content =~ s/(^|\s)(you're|you are) /$1${person_being_referenced} is /ig;
        $content =~ s/(^|\s)your /$1${person_being_referenced}\'s /ig;
    }
    
    return $content;
}

sub normalize_urls {
    my @words = split(/\s+/, $_[0]);
    my $curWord;
        
    foreach $curWord (@words) {
        # map some common host names to protocols
        $curWord =~ s{^(www|web)\.}{http://$1\.};
        $curWord =~ s{^ftp\.}{ftp://ftp\.};
        
        if($curWord =~ m{^((http|ftp|news|nntp|mailto|aim)s?:[\w.?/]+)}) {
            $curWord = $1;
            next;
        }
        
        if($curWord =~ m{/}) {
            my ($host, $path) = split(m{/}, $curWord, 2);
            
            # does the first segment have a TLD?
            if($host =~ m{\.(com|org|net|biz|info|aero|museum|\w\w)$}) {
                # Yup. Let's assume it's a web site...
                $host = 'http://' . $host;
            }
            $curWord = $host . '/' . $path;
        }
    }
    return join(' ', @words);
}

&SimBot::plugin_register(
    plugin_id   => 'info',
    plugin_desc => 'Tells you what simbot has learned about something.',
    event_plugin_call   => sub {}, # Do nothing.
    event_plugin_load   => \&messup_info,
    event_plugin_unload => \&cleanup_info,
    event_channel_message   => \&learn_info,
);

__END__
This is the code graveyard... I might need this for reference later, but
it's currently unused. I wouldn't touch this stuff if I were you...

sub get_info {
    my($kernel, $nick, $channel, undef, @query) = @_;

    $query = &munge_pronouns(join(' ', @query), $nick, $SimBot::nickname);

    if($query =~ m/^$/) {
        # looks like someone doesn't know what to do
        &SimBot::send_message($channel, "$nick: What d'ya wanna know?");
    } elsif($query =~ m{^forget (.*)}) {
        # looks like someone wants us to be forgetful
        my($forgotten, $key) = (0, lc($1));
        if($isDB{$key}) {
            delete $isDB{$key};
            $forgotten = 1;
        }
        if($areDB{$key}) {
            delete $areDB{$key};
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
