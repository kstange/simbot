###
#  SimBot Info Plugin
#
# DESCRIPTION:
#   The Info plugin is designed to bring Infobot style features to
#   SimBot. It'll learn things (factoids) from the channel, usually in
#   the form of "x is y". Later, when someone asks for it using
#   '%info x', SimBot will respond with what it knows about x. It will
#   even respond to "What is x?" type questions if it believes the
#   question wasn't asked of anyone in particular.
#
# COPYRIGHT:
#   Copyright (C) 2004, Pete Pearson
#
#   This program is free software; you can redistribute it and/or modify
#   under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#   
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#   
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
#
# TODO:
#   * We need a far more intelligent way to figure out where exactly the
#     factoid ends or the key begins.
#

package SimBot::plugin::info;

use warnings;

# These constants define the phrases simbot will use when responding
# to queries.
use constant I_DONT_KNOW => (
    '$nick: Damned if I know!',
    '$nick: Huh?',
    'I dunno, $nick.',
    'Tell me if you find out, $nick.',
);

use constant OK_LEARNED => (
    '$nick: I will remember that.', 'OK, $nick.',
    'I\'ll keep that in mind, $nick.',
);

use constant OK_FORGOTTEN => (
    '$nick: What were we talking about again?',
	'$nick: Information has been nullified!  Have a nice day.',
	'$nick: Done.  Wouldn\'t it be cool if %uline%you%uline% could forget on demand?',
);
use constant CANT_FORGET => (
    '$nick: I don\'t know anything about $key.'
);

use constant QUERY_RESPONSE => (
    '$nick: I have been told that $key $isare $factoid.',
    '$nick: Someone mentioned that $key $isare $factoid.',
    '$nick: $key, according to popular belief, $isare $factoid.',
);

use constant ALREADY_WAS => (
    'I already know that, $nick.',
    '$nick: You\'re telling me stuff I already know!',
);

use constant BUT_X_IS_Y => (
    '$nick: I thought $key $isare $factoid.',
);

use constant I_CANNOT => (    # used to respond to requests with bad words
    'I cannot do that, $nick.',
);

sub messup_info {
    dbmopen(%isDB, 'is', 0664);
    dbmopen(%areDB, 'are', 0664);
}

sub cleanup_info {
    dbmclose(%isDB); dbmclose(%areDB);
}

### handle_chat
# This method parses all messages said in the channel for things that
# appear to be queries or factoids and responds to and/or learns them
#
# Arugments:
#   $nick:      nickname of the person speaking
#   $channel:   channel the chat was in
#   $content:   content of the message
# Returns: nothing
sub handle_chat {
    my(undef, $nick, $channel, undef, $content) = @_;
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
            &report_learned($channel, $nick, $key, 'is', $factoid,
                            $being_addressed);
        }
    } elsif($content =~ m{([\'\w\s]+?) (is|are) ([\'\w\s]+)}i) {
        my ($key, $isare, $factoid) = (lc($1), $2, $3);

        foreach(@SimBot::chat_ignore) {
            if($content =~ /$_/) {
                &SimBot::send_message($channel, 
                    &parse_message(&SimBot::pick(I_CANNOT), $nick))
                    if $being_addressed;
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
                &SimBot::send_message($channel, 
                    &parse_message(&SimBot::pick(BUT_X_IS_Y), $nick,
                                   $key, 'is', $isDB{$key}))
                    if $being_addressed;
            } else {
                $isDB{$key} = $factoid;
                &report_learned($channel, $nick, $key, 'is', $factoid,
                                $being_addressed);
            }
        } else {
            if($areDB{$key}) {
                &SimBot::send_message($channel, 
                    &parse_message(&SimBot::pick(BUT_X_IS_Y), $nick,
                                   $key, 'are', $isDB{$key}))
                    if $being_addressed;
            } else {
                $areDB{$key} = $factoid;
                &report_learned($channel, $nick, $key, 'are', $factoid,
                                $being_addressed);
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

### handle_query
# This method takes a query and sends back to the channel the response
#
# Arguments:
#                    $query:  the key we are looking up
#                  $channel:  channel the chat was in
#   $person_being_addressed:  content of the message
#          $being_addressed:  are we being addressed?
# Returns: nothing
sub handle_query {
    my ($query, $nick, $channel, $person_being_addressed, $being_addressed)
        = @_;
    
    if($person_being_addressed && !$being_addressed) {
        # Someone's being referenced, and it isn't us.
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

### report_learned
# This method simply logs and reports to the channel that some fact
# has been learned.
#
# Arguments:
#   $channel:   channel the chat was in
#   $nick:      nickname of the person speaking
#   $key:       the key that was learned
#   $isare:     'is' or 'are'
#   $factoid:   the factoid that was learned
#   $addressed: were we addressed with %info?
# Returns: nothing
sub report_learned {
    my($channel, $nick, $key, $isare, $factoid, $addressed) = @_;
    &SimBot::debug(3, "Learning from $nick: $key =$isare=> $factoid\n");
    &SimBot::send_message($channel,
        &parse_message(&SimBot::pick(OK_LEARNED), $nick)
        . " ($key =$isare=> $factoid)")
        if $addressed;
}

### parse_message
# This method parses a string for certain variables, as well as for style
# Used for all the messages sent to the channel.
#
# Arguments:
#   $message:   the string we are working on
#   $nick:      the nickname we are speaking to
#   $key:       the key of the factoid that was learned, or undef
#   $isare:     'is', 'are', or undef
#   $factoid:   the factoid that was learned, or undef
# Returns: the parsed string
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
        $curWord =~ s{^(www|web)\.} {http://$1\.};
        $curWord =~ s{^ftp\.}       {ftp://ftp\.};
        
        if($curWord =~ m{^((http|ftp|news|nntp|mailto|aim)s?:[\w.?/]+)}) {
            $curWord = $1;
            next;
        }
        
        if($curWord =~ m{/}) {
            my ($host, $path) = split(m{/}, $curWord, 2);
            
            # does the first segment have a TLD?
            if($host =~ m{\.(com|org|net|int|mil|gov|edu|biz|pro|info|aero|coop|name|museum|\w\w)$}g) {
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
    event_channel_message   => \&handle_chat,
);
