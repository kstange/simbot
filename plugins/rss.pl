###
#  SimBot RSS Plugin
#
# DESCRIPTION:
#   This plugin announces to the channel when some web site using RSS
#   updates.
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
#   * 
#

use strict;
use warnings;
use XML::RSS;
use LWP::UserAgent;
use vars qw( %mostRecentPost %feeds $session);

# Configure feeds here. Key should be local cache name; value should be
# url to the RSS feed
$feeds{'fourohfour.xml'}    = 'http://fourohfour.info/rss.xml';
$feeds{'simguy.xml'}        = 'http://simguy.net/rss';
$feeds{'fourohfour-test.xml'} = 'http://fourohfour.info/rss-test.xml';
$feeds{'fark.xml'}          = 'http://www.pluck.com/rss/fark.rss';

use constant CHANNEL => '#simgames';

### messup_rss
# This runs when simbot loads. We need to make sure we know the
# most recent post on each feed at this time so when we update in an hour
# we can announce only new stuff.
sub messup_rss {    
    $session = POE::Session->create(
        inline_states => {
            _start => \&bootstrap,
            do_rss => \&do_rss,
            shutdown => \&shutdown,
        }
    );
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
    foreach my $curFeed (keys %feeds) {
        if(!-e "caches/$curFeed" || -M "caches/$curFeed" > 0.042) {
            # cache is nonexistent or stale
            
            #system('curl', '-o', "caches/$curFeed", $feeds{$curFeed});
            my $request = HTTP::Request->new(GET => $feeds{$curFeed});
            my $response = $useragent->request($request);
            unless($response->is_error) {
                open(OUT, ">caches/$curFeed");
                print OUT $response->content;
                close(OUT);
            }
        }
        $rss->parsefile("caches/$curFeed");
        $mostRecentPost{$curFeed} = $rss->{'items'}->[0]->{'link'};
    }
        
    &SimBot::debug(3, "...done!\n");
    
    $kernel->delay(do_rss => 3600)
}

### do_rss
# This is run on a timer, once an hour, to fetch new data and, if
# there is anything new, announce it.
sub do_rss {
    my $kernel = $_[KERNEL];
    my (@newPosts);
    my $rss = new XML::RSS;
    &SimBot::debug(3, "Updating RSS...\n");
    my $useragent = LWP::UserAgent->new(requests_redirectable => undef);
    $useragent->agent(SimBot::PROJECT . "/" . SimBot::VERSION);
    $useragent->timeout(8);
    
    foreach my $curFeed (keys %feeds) {
        #system('curl', '-o', "caches/$curFeed", $feeds{$curFeed});
        my $request = HTTP::Request->new(GET => $feeds{$curFeed});
        my $response = $useragent->request($request);
        @newPosts = ();
        unless($response->is_error) {
            open(OUT, ">caches/$curFeed");
            print OUT $response->content;
            close(OUT);
        
            $rss->parsefile("caches/$curFeed");
    
            foreach my $item (@{$rss->{'items'}}) {
                if($item->{'link'} eq $mostRecentPost{$curFeed}) {
                    last;
                } else {
                    push(@newPosts, "$item->{'title'} <$item->{'link'}>");
                }
            }
            $mostRecentPost{$curFeed} = $rss->{'items'}->[0]->{'link'};
        
            if(@newPosts) {
                &SimBot::send_message(CHANNEL, "$rss->{'channel'}->{'title'} has been updated! Here's what's new:");
                foreach(@newPosts) {
                    &SimBot::send_message(CHANNEL, $_);
                }
            }
        }
    }
    $kernel->delay(do_rss => 3600);
}

&SimBot::plugin_register(
    plugin_id   => 'rss',
#    plugin_desc => 'Tells you what simbot has learned about something.',
#    event_plugin_call   => sub {}, # Do nothing.
    event_plugin_load   => \&messup_rss,
    event_plugin_unload => \&cleanup_rss,
);