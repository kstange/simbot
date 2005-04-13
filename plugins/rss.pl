###
#  SimBot RSS Plugin
#
# DESCRIPTION:
#   This plugin announces to the channel when some web site using RSS
#   updates.
#
# REQUIRES:
#   * XML::RSS
#   * POE::Component::Client::HTTP
#   * HTML::Entities
#   * DBI, DBM::SQLite
#
# COPYRIGHT:
#   Copyright (C) 2004-05, Pete Pearson <http://fourohfour.info/>
#
#   This program is free software; you can redistribute and/or modify it
#   under the terms of version 2 of the GNU General Public License as
#   published by the Free Software Foundation.
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
#   * Make rss feed IDs case insensitive
#   * clean up old posts from the cache
#   * Atom feeds
#   * if the feed provides a polling interval, honor it
#

package SimBot::plugin::rss;

use strict;
use warnings;

use XML::RSS;
use HTML::Entities;
use POE;
use POE::Component::Client::HTTP;
use HTTP::Request::Common qw(GET POST);
use HTTP::Status;
use DBI;            # for the sqlite database

use Encode;         # so we can deal with unicode

# declare globals
use vars qw( %mostRecentPost $session $dbh $get_all_feeds_info_query
    $get_feed_info_query $get_feed_by_id_query $get_headline_query
    $insert_headline_query $update_headline_query
    $update_feed_title_query $done_initial_update);

use constant CHANNEL => &SimBot::option('network', 'channel');
use constant FEED_TITLE_STYLE => &SimBot::option('plugin.rss','title_style');
use constant EXPIRE => (&SimBot::option('plugin.rss', 'expire') ?
                            &SimBot::option('plugin.rss', 'expire') : 1500);

### messup_rss
# This runs when simbot loads. We need to make sure we know the most
# recent post on each feed at this time so when we update we can
# announce only new stuff.
sub messup_rss {
    # create our cache database
    $dbh = DBI->connect('dbi:SQLite:dbname=caches/rss','','',
        { RaiseError => 1, AutoCommit => 0 })
        or die;
    
    # let's create the table. If this fails, we don't care, as it
    # probably already exists
    {
        local $dbh->{RaiseError}; # let's not die on errors
        local $dbh->{PrintError}; # and let's be quiet
        $dbh->do(<<EOT);
CREATE TABLE headlines (
    id INTEGER PRIMARY KEY,
    feed_id INTEGER,
    time INTEGER,
    guid STRING,
    title STRING,
    url STRING
);
EOT
        $dbh->do(<<EOT);
CREATE TABLE feeds (
    id INTEGER PRIMARY KEY,
    name STRING,
    key STRING,
    last_update INTEGER,
    url STRING,
    announce INTEGER
);
EOT
        
        $dbh->do(<<EOT);
CREATE UNIQUE INDEX feedkey
    ON feeds (key);
EOT

        $dbh->do(<<EOT);
CREATE TRIGGER delheadlines
    BEFORE DELETE ON feeds
    FOR EACH ROW
    BEGIN
        DELETE FROM headlines WHERE feed_id = old.id;
    END;
EOT
    }
    
    $get_feed_info_query = $dbh->prepare(
        'SELECT * FROM feeds WHERE key = ?'
    );
    $get_feed_by_id_query = $dbh->prepare(
        'SELECT * FROM feeds WHERE id = ?'
    );
    $get_all_feeds_info_query = $dbh->prepare(
        'SELECT * FROM feeds'
    );
    $get_headline_query = $dbh->prepare(
        'SELECT * FROM headlines WHERE feed_id = ? AND (guid = ? OR url = ?)'
    );
    $insert_headline_query = $dbh->prepare(
        'INSERT INTO headlines (feed_id, time, guid, title, url)'
        . ' VALUES (?, ?, ?, ?, ?)'
    );
    $update_feed_title_query = $dbh->prepare(
        'UPDATE feeds SET name = ?, last_update = ? WHERE id = ?'
    );
    my (%feeds, %announce_feed);
    my $update_feed_query = $dbh->prepare(
        'UPDATE feeds SET url = ?, announce = ? WHERE id = ?'
    );
    my $insert_feed_query = $dbh->prepare(
        'INSERT INTO feeds (key, url, announce) VALUES (?, ?, ?)'
    );
    
    foreach my $cur_feed
            (split(/,/, &SimBot::option('plugin.rss', 'announce'))) {
        $announce_feed{$cur_feed} = 1;
    }
    foreach my $cur_feed
            (&SimBot::options_in_section('plugin.rss.feeds')) {
        $feeds{$cur_feed}=1;
        $get_feed_info_query->execute($cur_feed);
        
        if(my $id = ($get_feed_info_query->fetchrow_array)[0]) {
            # feed is already in the table, let's update it
            $update_feed_query->execute(
                &SimBot::option('plugin.rss.feeds', $cur_feed),
                (defined $announce_feed{$cur_feed} ? 1 : 0),
                $id
            );
        } else {
            # we need to add the feed
            $insert_feed_query->execute(
                $cur_feed,
                &SimBot::option('plugin.rss.feeds', $cur_feed),
                (defined $announce_feed{$cur_feed} ? 1 : 0)
            );
        }
    }
    
    my $delete_feed_query = $dbh->prepare(
        'DELETE FROM feeds WHERE id = ?'
    );
    
    $get_all_feeds_info_query->execute;
    while(my ($id, undef, $key) = $get_all_feeds_info_query->fetchrow_array) {
        unless(defined $feeds{$key}) {
            # the feed isn't in the config file. Let's remove it.
            $delete_feed_query->execute($id);
        }
    }
    
    $dbh->commit;
    
    POE::Component::Client::HTTP->spawn
		( Alias => 'ua',
		  Timeout => 120,
		  Agent => SimBot::PROJECT . "/" . SimBot::VERSION,
       );

    $session = POE::Session->create(
        inline_states => {
            _start          => \&do_rss,
            do_rss          => \&do_rss,
            got_response    => \&got_response,
            announce_top    => \&announce_top,
            latest_headlines
                            => \&latest_headlines,
            shutdown        => \&shutdown,
        }
    );
    
    1;
}

### cleanup_rss
# This runs when simbot wants us to die.
sub cleanup_rss {
    $_[0]->post($session, 'shutdown');
}

### shutdown
# This is run when POE tells us to die.
sub shutdown {
    $_[KERNEL]->alarm_remove_all();
}

### do_rss
# This is run on a timer, once an hour or as specified by the EXPIRE
# option, to fetch new data and, if there is anything new, announce it.
sub do_rss {
    my $kernel = $_[KERNEL];
    my (@newPosts, $title, $request, $file);
    my $rss = new XML::RSS;
    &SimBot::debug(3, "rss: Updating cache...\n");

    $get_all_feeds_info_query->execute;
    while(my ($id, undef, $key, $last_update, $url, $announce)
        = $get_all_feeds_info_query->fetchrow_array) {
        
        # if we aren't announcing the feed, we'll fetch it when
        # someone asks for it.
        if(!$announce) { next; } 

        $request = HTTP::Request->new(GET => $url);
        if(defined $last_update) {
            $request->if_modified_since($last_update);
        }
        
        # if our cache is out of date, update it.
        if(!defined $last_update
            || $last_update + EXPIRE <= time) {
            unless(defined $done_initial_update) {
                $id .= '!!-';
            }
            $kernel->post('ua' => 'request', 'got_response',
                $request, $id);
        }
    }
    $done_initial_update = 1;

    $kernel->delay(do_rss => EXPIRE);
}

### got_response
# This is run whenever we have retrieved a RSS feed. We dump it
# to disk.
sub got_response {
    my ($kernel, $request_packet, $response_packet)
        = @_[ KERNEL, ARG0, ARG1 ];
    my (@newPosts);
    my ($id, $nick) = split(/!!/, $request_packet->[1]);
    my $response = $response_packet->[0];
    my $rss = new XML::RSS;
    
    $get_feed_by_id_query->execute($id);
    my (undef, $feed_name, $key, $last_update, $feed_url, $announce)
        = $get_feed_by_id_query->fetchrow_array;

    &SimBot::debug((($response->code >= 400) ? 1 : 4),
				   "rss:   fetching feed for $key: "
				   . $response->status_line . "\n");

    if($response->code == RC_GONE) {
        # Server is telling us the file is gone.
        
        &SimBot::debug(1,
                     "rss:   *** FEED $key IS NO LONGER AVAILABLE\n"
            . "              *** Removing $key from cache\n"
            . "              *** Please remove $key from your config file\n");
        
        my $delete_feed_query = $dbh->prepare(
            'DELETE FROM feeds WHERE key = ?'
        );
        $delete_feed_query->execute($key);
        
        if(defined $nick) {
            # either we are responding to someone's initial request
            # or $nick is '-' and this is the initial cache update
            if($nick ne '-') {
                &SimBot::send_message(CHANNEL, "$nick: Sorry, that feed is no longer available.");
            }
        }
        return;
        
    } elsif($response->code == RC_NOT_MODIFIED) {
        # File wasn't modified. We update the modified time...
        $last_update = time;
    } elsif($response->is_success) {
        $last_update = time;
        if (!eval { $rss->parse($response->content); }) {
			&SimBot::debug(1, "rss:  Parse error in $key: $@");
			return;
        }
        $feed_name = $rss->{'channel'}->{'title'};
        if($feed_name =~ m/Slashdot Journals/) {
            $feed_name = $rss->{'channel'}->{'description'};
        }
        foreach my $item (reverse @{$rss->{'items'}}) {
            no warnings qw( uninitialized );
            
            my ($url, $title) = &get_link_and_title($item);
                
            $get_headline_query->execute($id, $item->{'guid'},
                                        $url);
            if(my ($hid, undef, $time, $guid, undef, undef)
                = $get_headline_query->fetchrow_array) {
                # well, the headline's been seen already.
                # let's update it in case anything changed.
                $guid = $item->{'guid'};
                ($url, $title) = &get_link_and_title($item);
                
                # FIXME: update headline
            } else {
                # we haven't seen this headline yet
                # add it, then figure out if we should announce it.
                $insert_headline_query->execute(
                    $id,
                    undef, # FIXME: time of headline
                    $item->{'guid'},
                    $title,
                    $url
                );
                
                if($announce) {
                    push(@newPosts, "$title  $url");
                }
            }
        }
    }
    
    $update_feed_title_query->execute($feed_name, $last_update, $id);
    
    $dbh->commit;
    
    if(defined $nick) {
        # either we are responding to someone's initial request
        # or $nick is '-' and this is the initial cache update
        if($nick ne '-') {
            $kernel->yield('announce_top', $id, $nick, CHANNEL);
        }
        return;
    }
    if($announce && @newPosts) {
        &SimBot::send_message(CHANNEL,
          &SimBot::parse_style(&colorize_feed($feed_name)
                        . " has been updated! Here's what's new:"));
        foreach(@newPosts) {
            &SimBot::send_message(CHANNEL, $_);
        }
    }
}

### latest_headlines_stub
# SimBot does not know this is a POE session.  It will call this
# function and we'll post our event.
sub latest_headlines_stub {
    my ($kernel, $nick, $channel, undef, $feed) = @_;
    $kernel->post($session => 'latest_headlines', $nick,
                  $channel, $feed);
}

### latest_headlines
# This outputs the latest headlines for the requested feed to IRC.
sub latest_headlines {
    my ($kernel, $nick, $channel, $feed)
        = @_[ KERNEL, ARG0, ARG1, ARG2 ];
    my ($item, $title, $link);
    my $rss = new XML::RSS;

    &SimBot::debug(3, "rss: Got request from $nick" .
				   (defined $feed ? " for $feed" : "") . "...\n");
    $get_feed_info_query->execute($feed);
    
    if(my ($id, undef, undef, $last_update, $url, undef)
        = $get_feed_info_query->fetchrow_array) {
        
        # yay, we know about the feed
        # is the cache up to date?
        if(!defined $last_update || $last_update > time - EXPIRE) {
            # cache is stale or missing
            &SimBot::debug(4, "rss: $feed is old or missing.\n");
            my $request = HTTP::Request->new(GET => $url);
            $request->if_modified_since($last_update);
            
            $kernel->post('ua' => 'request', 'got_response',
                $request, "$id!!$nick");
        } else {
            &SimBot::debug(4,
                           "rss: $feed is up to date; Displaying.\n");
            $kernel->post($session => 'announce_top', $id, $nick,
                        $channel);
        }
    } else {
        &SimBot::debug(4, "rss: No feed matched request.\n");
        my $message = "$nick: "
            . ($feed ? "I have no feed $feed."
                     : "What feed do you want latest posts from?")
            . ' Try one of:';
        $get_all_feeds_info_query->execute;
        while(my $key = ($get_all_feeds_info_query->fetchrow_array)[2])
        {
            $message .= " $key";
        }
        &SimBot::send_message($channel, $message);
    }
}

### announce_top
# Called when someone requests the top few headlines for a feed, and
# we already have an up to date cache
sub announce_top {
    my ($id, $nick, $channel) = @_[ ARG0, ARG1, ARG2 ];
    my ($rss, $link, $title, $item);
	
    my $get_top_headlines_query = $dbh->prepare(
        'SELECT title, url FROM headlines'
        . ' WHERE feed_id = ?'
        . ' ORDER BY id desc'
        . ' LIMIT 3'
    ); # FIXME: we should be ordering by a time of some sort
    # ID is *not* necessarily in the order we want (but should be
    # until it wraps around)
    
    $get_top_headlines_query->execute($id);
	
	$get_feed_by_id_query->execute($id);
	my $feed_name = ($get_feed_by_id_query->fetchrow_array)[1];
	
	my @posts;
	
    while(my ($title, $url) = $get_top_headlines_query->fetchrow_array)
    {
        Encode::_utf8_on($title);
        push(@posts, "$title  $url");
    }
    if(@posts) {
        &SimBot::send_message(CHANNEL,
            &SimBot::parse_style("$nick: Here are the latest posts to "
                . &colorize_feed($feed_name) . ':'));
        foreach(@posts) {
            &SimBot::send_message(CHANNEL, $_);
        }
    } else {
        &SimBot::send_message(CHANNEL, "$nick: Hmm... That feed seems to be empty!");
    }
}

sub colorize_feed {
    my $feed = $_[0];
    if(defined FEED_TITLE_STYLE) {
        return FEED_TITLE_STYLE . $feed . '%normal%';
    } else {
        return $feed;
    }
}

sub get_link_and_title {
    my $item = $_[0];
    my $link = $item->{'link'};
    my $title = $item->{'title'};

    # Does the link go through the silly Fark redirect?
    # If so, let's remove it.
    if($link =~ s{^http://go\.fark\.com/cgi/fark/go\.pl\?\S*&location=(\S*)$}{$1}) {
        $link =~ s{%3f}{?};
        $link =~ s{%26}{&}g;
    }

    $title = ($item->{'title'} ? $item->{'title'} : "");
    $title = HTML::Entities::decode($title);
    $title =~ s/\t/  /g;

    return ($link, $title);
}

sub nlp_match {
    my ($kernel, $nick, $channel, $plugin, @params) = @_;

	my $feed;

	foreach (@params) {
		if (m/(\w+)\'s (rss|feed|posts|headlines)/i) { # '
			$feed = $1;
		} elsif (m/(\w+) (\w+)/i) {
			$feed = $2;
		}
	}

	if (defined $feed) {
		$kernel->post($session => 'latest_headlines', $nick, $channel,
		              $feed);
		return 1;
	} else {
		return 0;
	}
}

&SimBot::plugin_register(
    plugin_id   => 'rss',
    plugin_desc => 'Lists the three most recent posts in the requested RSS feed.',
    event_plugin_call     => \&latest_headlines_stub,
    event_plugin_load     => \&messup_rss,
    event_plugin_unload   => \&cleanup_rss,

	event_plugin_nlp_call => \&nlp_match,
	hash_plugin_nlp_verbs =>
						 ["rss", "feed", "posts", "headlines", "news"],
	hash_plugin_nlp_formats =>
						 ["{at} {w}", "{on} {w}", "{for} {w}", "{from} {w}",
						  "{w}\'s rss", "{w}\'s feed", "{w}\'s posts",
						  "{w}\'s headlines"],
	hash_plugin_nlp_questions =>
						 ["what-are", "command","i-want",
						  "i-need", "how-about", "you-must"],
);
