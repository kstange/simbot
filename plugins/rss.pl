###
#  SimBot RSS Plugin
#
# DESCRIPTION:
#   This plugin announces to the channel when some web site using RSS
#   updates.
#
# REQUIRES:
#   * XML::RSS
#   * LWP::UserAgent (you should have this already)
#   * POE::Component::Client::HTTP
#
# COPYRIGHT:
#   Copyright (C) 2004, Pete Pearson <http://fourohfour.info/>
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
#   * Switch to PoCo::Client::HTTP for the startup RSS fetch
#   * Move feed option to config.ini file
#   * Find a better way to detect new posts in feeds
#

package SimBot::plugin::rss;

use strict;
use warnings;
use XML::RSS;
use LWP::UserAgent;
use POE;
use POE::Component::Client::HTTP;
use HTTP::Request::Common qw(GET POST);
use HTTP::Status;
use vars qw( %mostRecentPost %feeds %announce_feed $session );

# Configure feeds here. Key should be local cache name; value should be
# url to the RSS feed
$feeds{'fourohfour'}        = 'http://fourohfour.info/rss.xml';
$announce_feed{'fourohfour'} = 1;

$feeds{'simguy'}            = 'http://simguy.net/rss';
$announce_feed{'simguy'}    = 1;

$feeds{'slashdot'}          = 'http://slashdot.org/index.rss';
$announce_feed{'slashdot'}  = 1;

$feeds{'fark'}              = 'http://www.pluck.com/rss/fark.rss';
$announce_feed{'fark'}      = 0;

$feeds{'lpetr'}             = 'http://slashdot.org/journal.pl?op=display&uid=557952&content_type=rss';
$announce_feed{'lpetr'}     = 1;

$feeds{'ala'}               = 'http://www.alistapart.com/rss.xml';
$announce_feed{'ala'}       = 1;

use constant CHANNEL => &SimBot::option('network', 'channel');

### messup_rss
# This runs when simbot loads. We need to make sure we know the
# most recent post on each feed at this time so when we update in an hour
# we can announce only new stuff.
sub messup_rss {    
    $session = POE::Session->create(
        inline_states => {
            _start          => \&bootstrap,
            do_rss          => \&do_rss,
            got_response    => \&got_response,
            shutdown        => \&shutdown,
        }
    );
    POE::Component::Client::HTTP->spawn
      ( Alias => 'ua',
        Timeout => 120,
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

### bootstrap
# This is called by POE when it loads.
sub bootstrap {
    my $kernel = $_[KERNEL];
    my $rss = new XML::RSS;
    my $useragent = LWP::UserAgent->new(requests_redirectable => undef);
    $useragent->agent(SimBot::PROJECT . "/" . SimBot::VERSION);
    $useragent->timeout(8);
    
    &SimBot::debug(3, "Updating RSS cache... \n");
    my $file;
    foreach my $curFeed (keys %feeds) {
        $file = "caches/${curFeed}.xml";
        if(!-e $file || -M $file > 0.042) {
            # cache is nonexistent or stale
            &SimBot::debug(3, "   Fetching ${curFeed}: ");
            #system('curl', '-o', "caches/$curFeed", $feeds{$curFeed});
            my $request = HTTP::Request->new(GET => $feeds{$curFeed});
            if(-e $file) {
                my $mtime = (stat($file))[9];
                $request->if_modified_since($mtime);
            }
            my $response = $useragent->request($request);
            &SimBot::debug(3, $response->status_line . "\n");
            if($response->code == RC_NOT_MODIFIED) {
                # File wasn't modified. We touch the file so we don't
                # request it again for an hour
                my $now = time;
                utime($now, $now, $file);
            } elsif($response->is_success) {
                open(OUT, ">$file");
                print OUT $response->content;
                close(OUT);
            }
        }
        $rss->parsefile($file);
        $mostRecentPost{$curFeed} = $rss->{'items'}->[0]->{'link'};
    }

    $kernel->delay(do_rss => 3600);
}

### do_rss
# This is run on a timer, once an hour, to fetch new data and, if
# there is anything new, announce it.
sub do_rss {
    my $kernel = $_[KERNEL];
    my (@newPosts, $title, $request, $file);
    &SimBot::debug(3, "Updating RSS...\n");
#    my $useragent = LWP::UserAgent->new(requests_redirectable => undef);
#    $useragent->agent(SimBot::PROJECT . "/" . SimBot::VERSION);
#    $useragent->timeout(8);
    
    foreach my $curFeed (keys %feeds) {
        $file = "caches/${curFeed}.xml";
        $request = HTTP::Request->new(GET => $feeds{$curFeed});
        if(-e $file) {
            my $mtime = (stat($file))[9];
            $request->if_modified_since($mtime);
        }
        $kernel->post( 'ua' => 'request', 'got_response',
                        $request, $curFeed);
    }
    $kernel->delay(do_rss => 3600);
}   

### got_response
# This is run whenever we have retrieved a RSS feed. We dump it
# to disk and ask and post an event to parse it later.
sub got_response {
    my ($request_packet, $response_packet) = @_[ ARG0, ARG1 ];
    my (@newPosts, $title, $link, $file);
    my $curFeed = $request_packet->[1];
    my $response = $response_packet->[0];
    my $rss = new XML::RSS;
    $file = "caches/${curFeed}.xml";
    &SimBot::debug(3, "  got RSS for $curFeed: "
                      . $response->status_line . "\n");
    
    if($response->code == RC_NOT_MODIFIED) {
        # File wasn't modified. We touch the file so we don't
        # request it again for an hour
        my $now = time;
        utime($now, $now, $file);
    } elsif($response->is_success) {
        open(OUT, ">$file");
        print OUT $response->content;
        close(OUT);
    
        if($announce_feed{$curFeed}) {

            $rss->parsefile("caches/${curFeed}.xml");
        
            foreach my $item (@{$rss->{'items'}}) {
                if($item->{'link'} eq $mostRecentPost{$curFeed}) {
                    last;
                } else {
                    $title = $item->{'title'};
                    $link = $item->{'link'};
                    $title =~ s/&quot;/\"/ig;
                    $title =~ s/&amp;/&/ig;
                    $title =~ s/\t/  /g;
                    
                    $link =~ s{^http://go\.fark\.com/cgi/fark/go\.pl\?\S*&location=(\S*)$}{$1};
                    
                    push(@newPosts, "$title <$link>");
                }
            }
            $mostRecentPost{$curFeed} = $rss->{'items'}->[0]->{'link'};
        
            if(@newPosts) {
                $title = $rss->{'channel'}->{'title'};
                if($title =~ m/Slashdot Journals/) {
                    $title = $rss->{'channel'}->{'description'};
                }
                &SimBot::send_message(CHANNEL, "$title has been updated! Here's what's new:");
                foreach(@newPosts) {
                    &SimBot::send_message(CHANNEL, $_);
                }
            }
        }
    }
}

### latest_headlines
# gets the latest headlines for the specified feed.

sub latest_headlines {
    my (undef, $nick, $channel, undef, $feed) = @_;
    my ($item, $title, $link);
    my $rss = new XML::RSS;
    
    if(defined $feeds{$feed}) {
        $rss->parsefile("caches/${feed}.xml");
        $title = $rss->{'channel'}->{'title'};
        if($title =~ m/Slashdot Journals/) {
            $title = $rss->{'channel'}->{'description'};
        }
        &SimBot::send_message($channel,
                        "$nick: Here are the latest posts to $title:");
#        foreach my $item (@{$rss->{'items'}}) {
        for(my $i=0;
            $i <= ($#{$rss->{'items'}} < 2 ? $#{$rss->{'items'}} : 2);
            $i++)
          {
            $item = ${$rss->{'items'}}[$i];
            $link = $item->{'link'};
            $title = $item->{'title'};
            $title =~ s/&quot;/\"/;
            $title =~ s/&amp;/&/;
            $title =~ s/\t/  /;
            
            $link =~ s{^http://go\.fark\.com/cgi/fark/go\.pl\?\S*&location=(\S*)$}{$1};
            
            &SimBot::send_message($channel, "$title <$link>");
        }
    } else {
        my $message = "$nick: "
            . ($feed ? "I have no feed $feed."
                     : "What feed what do you want latest posts from?")
            . ' Try one of:';
        foreach(sort keys %feeds) {
            $message .= " $_";
        }
        &SimBot::send_message($channel, $message);
    }
}

&SimBot::plugin_register(
    plugin_id   => 'rss',
    plugin_desc => 'Lists the three most recent posts in the requested RSS feed.',
    event_plugin_call   => \&latest_headlines,
    event_plugin_load   => \&messup_rss,
    event_plugin_unload => \&cleanup_rss,
);
