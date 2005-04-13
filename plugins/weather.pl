###
#  SimBot Weather Plugin
#
# DESCRIPTION:
#   Provides the ability to get the current weather conditions for one's
#   locale  to SimBot. Responds to "%weather xxxx" with the current
#   conditions for the location xxxx, where xxxx is a station providing
#   METAR reports. The four character station IDs can be looked up
#   online at <http://www.nws.noaa.gov/tg/siteloc.shtml>.
#
# COPYRIGHT:
#   Copyright (C) 2003-05, Pete Pearson
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
#   * locally cache reports, don't rerequest more than once an hour
#     SQLite maybe?
#   * Known stations searching. (%weather ny should be able to list
#     stations in NY. %weather massena, ny should get the weather for
#     KMSS)
#   * Find a way to convert zip codes to lat/long, use to find closest
#     station
#   * KILL Geo::METAR DAMN IT
#   * Forecasts would be nice. http://www.nws.noaa.gov/forecasts/xml/
#   * Fix crash if simbot quits before station name cache is updated
#       (don't try to update DB if it's closed)

package SimBot::plugin::weather;

use strict;
use warnings;

# The weather, more or less!
use Geo::METAR;

# the new fangled XML weather reports need to be parsed too!
use XML::Simple;

use POE;

# Fetching from URLs is better with LWP!
#use LWP::UserAgent;
# and even better with PoCo::Client::HTTP!
use POE::Component::Client::HTTP;
use HTTP::Request::Common qw(GET POST);
use HTTP::Status;

use DBI;    # for sqlite database

# declare globals
use vars qw( $session $dbh );

# These constants define the phrases simbot will use when responding
# to weather requests.
use constant STATION_LOOKS_WRONG =>
    'That doesn\'t look like a METAR station. ';

use constant STATION_UNSPECIFIED =>
    'Please provide a METAR station ID. ';

use constant FIND_STATION_AT => 'You can look up station IDs at http://www.nws.noaa.gov/tg/siteloc.shtml .';

use constant CANNOT_ACCESS => 'Sorry; I could not access NOAA.';


### cleanup_wx
# This method is run when SimBot is exiting. We save the station names
# cache here.
sub cleanup_wx {
    $dbh->disconnect;
}

### messup_wx
# This method is run when SimBot is loading. We load the station names
# cache here. We also start our own POE session so we can wait for NOAA
# instead of giving up quickly so as to not block simbot
sub messup_wx {
    # let's create our database
    $dbh = DBI->connect('dbi:SQLite:dbname=caches/weather','','',
        { RaiseError => 1, AutoCommit => 0 }) or die;
        
    # let's create the table. If this fails, we don't care, as it
    # probably already exists
    {
        local $dbh->{RaiseError}; # let's not die on errors
        local $dbh->{PrintError}; # and let's be quiet
        
        $dbh->do(<<EOT);
CREATE TABLE stations (
    id STRING UNIQUE,
    name STRING,
    state STRING,
    country STRING,
    latitude REAL,
    longitude REAL,
    url STRING
);

CREATE UNIQUE INDEX stationid
    ON stations (id);
EOT
        # conditions will be cached in the database eventually
        # add the conditions table here, and a trigger to delete
        # cached conditions if the station is deleted.

    }    

    $dbh->commit;

    POE::Component::Client::HTTP->spawn
        ( Alias => 'wxua',
          Timeout => 120,
        );
    $session = POE::Session->create(
        inline_states => {
            _start          => \&bootstrap,
            do_wx           => \&do_wx,
            got_wx          => \&got_wx,
            got_xml         => \&got_xml,
            got_station_name => \&got_station_name,
            got_station_list => \&got_station_list,
            shutdown        => \&shutdown,
        }
    );
    1;
}

sub bootstrap {
    my $kernel = $_[KERNEL];
    # Let's set an alias so our session will hang around
    # instead of just leaving since it has nothing to do
    $kernel->alias_set('wx_session');
    
    # and let's go update our known stations list...
    &SimBot::debug(3, "weather: Updating known stations...\n");
    my $request = HTTP::Request->new(GET=>'http://www.nws.noaa.gov/data/current_obs/index.xml');
    $kernel->post('wxua' => 'request', 'got_station_list',
                $request);
}

### do_wx
# this is called when POE tells us someone wants weather
sub do_wx {
    my  ($kernel, $nick, $station, $metar_only) =
      @_[KERNEL,  ARG0,  ARG1,     ARG2];

    &SimBot::debug(3, 'weather: Received request from ' . $nick
        . " for $station\n");

    if(length($station) != 4) {
        # Whine and bail
        &SimBot::send_message(&SimBot::option('network', 'channel'),
                              "$nick: "
                              . ($station ? STATION_LOOKS_WRONG
                                          : STATION_UNSPECIFIED)
                              . FIND_STATION_AT);
        return;
    }

    $station = uc($station);
    
    # Try to look up the station in the database.
    # if it is there, check for a URL
    # if there is no URL, it's metar, go do that
    # if there is a URL, it's XML, go do that
    # if it is not there, it's metar, go do that.
    my $query = $dbh->prepare(
        'SELECT name, url FROM stations'
        . ' WHERE id = ?'
    );
    $query->execute($station);
    my ($station_name, $url);
    if((($station_name, $url) = $query->fetchrow_array)
        && !$metar_only
        && (defined $url)) {
        my $request = HTTP::Request->new(GET=>$url);
        $kernel->post('wxua' => 'request', 'got_xml',
            $request, "$nick!$station");
        
        return;
    }

    # Damn, guess we need to parse METAR.
    
    # do we have a station name?
    unless(defined $station_name) {
        &SimBot::debug(4,
            "weather: Station name not found, looking it up\n");
        my $url =
            'http://weather.noaa.gov/cgi-bin/nsd_lookup.pl?station='
            . $station;
        my $request = HTTP::Request->new(GET => $url);
        $kernel->post('wxua' => 'request', 'got_station_name',
                      $request, "$nick!$station!$metar_only");
        # We're done here - got_station_name will handle requesting
        # the weather
        return;
    }
    # we already have the station name... let's request the weather

    $url =
        'http://weather.noaa.gov/pub/data/observations/metar/stations/'
        . $station . '.TXT';
    my $request = HTTP::Request->new(GET=>$url);
    $kernel->post('wxua' => 'request', 'got_wx',
                            $request, "$nick!$station!$metar_only");
}

sub got_station_list {
    my ($kernel, $request_packet, $response_packet)
        = @_[KERNEL, ARG0, ARG1];
        
    my $response = $response_packet->[0];
    
    if($response->is_error) {
        &SimBot::debug(3, "weather: Could not get station list!\n");
        return;
    }
    my $xml;
    if (!eval { $xml = XMLin($response->content, SuppressEmpty => 1); }) {
		&SimBot::debug(3, "weather: XML parse error for stations list: $@\n");
		return;
    }
    &SimBot::debug(3, "weather: Got station list.\n");
    
    my $update_station_query = $dbh->prepare(
        'INSERT OR REPLACE INTO stations (id, name, state, country, latitude, longitude, url)'
        . ' VALUES (?,?,?,?,?,?,?)');
        
    foreach my $cur_station (@{$xml->{'station'}}) {
        no warnings qw( uninitialized );

# NOAA seems to be inconsistant with how they represent
# latitude and longitude. It appears to be degrees.minutes.seconds
# but in some cases the number is X.Y . Is that X degrees, Y minutes,
# and 0 seconds, or X.Y degrees?
# I'll figure it out later... most stations just report NA anyway.
#        my ($latitude, $dir)
#            = $cur_station->{'latitude'}
#              =~ m/([\d\.]+)([NS])/;
#              
#        if($dir eq 'S') {
#            $latitude = $latitude * -1;
#        }
#        
#        my $longitude;
#        ($longitude, $dir)
#            = $cur_station->{'longitude'}
#              =~ m/([\d\.]+)([EW])/;
#              
#        if($dir eq 'W') {
#            $longitude = $longitude * -1;
#        }
            
        $update_station_query->execute(
            $cur_station->{'station_id'},
            $cur_station->{'station_name'},
            $cur_station->{'state'},
            'United States',
            undef, #$latitude,
            undef, #$longitude,
            $cur_station->{'xml_url'}
        );
    }
    $dbh->commit;
}

sub got_station_name {
    my ($kernel, $request_packet, $response_packet)
        = @_[KERNEL, ARG0, ARG1];
    my ($nick, $station, $metar_only)
        = (split(/!/, $request_packet->[1], 3));
    my $response = $response_packet->[0];

    if (!$response->is_error
        && $response->content !~ /The supplied value is invalid/
        && $response->content !~ /No station matched the supplied identifier/)
    {
        
        $response->content =~ m|Station Name:.*?<B>(.*?)\s*</B>|s;
        my $name = $1;
        $response->content =~ m|State:.*?<B>(.*?)\s*</B>|s;
        my $state = ($1 eq $name ? undef : $1);
        $response->content =~ m|Country:.*?<B>(.*?)\s*</B>|s;
        my $country = $1;
        
        my $update_station_query = $dbh->prepare(
            'INSERT OR REPLACE INTO stations (id, name, state, country, latitude, longitude, url)'
            . ' VALUES (?,?,?,?,?,?,?)');
        $update_station_query->execute(
            $station,
            $name,
            $state,
            $country,
            undef, #FIXME: lat
            undef, #FIXME: long
            undef # URL is undef for metar
        );
        $dbh->commit;
    }
    &SimBot::debug(4, "weather: Got station name for $station\n");
    # ok, now we have the station name... let's request the weather
    my $url =
        'http://weather.noaa.gov/pub/data/observations/metar/stations/'
        . $station . '.TXT';
    my $request = HTTP::Request->new(GET=>$url);
    $kernel->post('wxua' => 'request', 'got_wx',
                  $request, "$nick!$station!$metar_only");
}

sub got_wx {
    # This parses METAR reports.
    # This should be replaced with something.
    # Either stop using Geo::METAR, or find some service that gives
    # us XML reports like NOAA does for US stations.
    
    my ($kernel, $request_packet, $response_packet)
        = @_[KERNEL, ARG0, ARG1];
    my ($nick, $station, $metar_only)
        = (split(/!/, $request_packet->[1], 3));
    my $response = $response_packet->[0];

    &SimBot::debug(4, 'weather: Got weather for ' . $nick
        . " for $station\n");

    if ($response->is_error) {
        if ($response->code eq '404') {
            &SimBot::send_message(&SimBot::option('network', 'channel'), "$nick: Sorry, there is no METAR report available matching \"$station\". " . FIND_STATION_AT);
        } else {
            &SimBot::send_message(
                &SimBot::option('network', 'channel'),
                "$nick: " . CANNOT_ACCESS);
        }
        return;
    }
    my (undef, $raw_metar) = split(/\n/, $response->content);

    # Geo::METAR has issues not ignoring the remarks section of the
    # METAR report. Let's strip it out.
    &SimBot::debug(4, "weather: METAR is " . $raw_metar . "\n");

    my $station_name_query = $dbh->prepare(
        'SELECT name, state, country FROM stations'
        . ' WHERE id = ?');
    $station_name_query->execute($station);
    my $station_name;
    if(my ($name, $state, $country)
         = $station_name_query->fetchrow_array)
    {
        $station_name =
            "${name}, "
            . (defined $state ? "${state}, " : '')
            . $country
            . " (${station})";
    } else {
        $station_name = $station;
    }
    
    if($metar_only) {
        &SimBot::send_message(&SimBot::option('network', 'channel'),
            "$nick: METAR report for $station_name is $raw_metar.");
        return;
    }

    my $wind_mph;
            
    my $remarks;
    ($raw_metar, undef, $remarks)
        = $raw_metar =~ m/^(.*?)( RMK (.*))?$/;
    $raw_metar =~ s|/////KT|00000KT|;
    &SimBot::debug(5, "weather: Reduced METAR is " . $raw_metar . "\n");

    my $m = new Geo::METAR;
    $m->metar($raw_metar);

    # Let's form a response!
    if (!defined $m->{date_time}) {
        # Something is very weird about this METAR.  It has no date,
        # so we are probably not going to get anything useful out of
        # it.
        &SimBot::send_message(&SimBot::option('network', 'channel'),
            "$nick: The METAR report for $station_name didn't make any sense to me.  Try "
                . &SimBot::option('global', 'command_prefix')
                . "metar $station if you want to try parsing it yourself.");
        return;
    }

	$m->{date_time} =~ m/(\d\d)(\d\d)(\d\d)Z/;
	my $time = "$2:$3";
	my $day=$1;

    my $reply = "As reported at $time GMT at $station_name";
    my @reply_with;

    # There's no point in this exercise unless there's data in there
    if ($raw_metar =~ /NIL$/) {
        $reply .= " there is no data available";
    } else {
        # Temperature and related details *only* if we have
        # a temperature!
        if (defined $m->TEMP_C || $raw_metar =~ m|(M?\d\d)/|) {
            # We have a temp, "it is"
            $reply .= " it is ";

            # This nonsense checks to see if we have a temperature in
            # the report that Geo::METAR is too stupid to see.
            my $temp_c = (defined $m->TEMP_C ? $m->TEMP_C : $1);
            $temp_c =~ s/M/-/;
            my $temp_f = (defined $m->TEMP_F ? $m->TEMP_F
                          : (9/5)*$temp_c+32);

            my $temp = $temp_f . '°F (' . int($temp_c) . '°C)';
            push(@reply_with, $temp);

            # this nonsense checks for the odd wind declaration NZSP
            # gives. I dunno what to make of the first part, I
            # suspect it is a direction. Compass directions don't make
            # much sense where every direction is north ;-)
            if($raw_metar =~ m|(GRID\d{2}(\d{3}))|) {
                $wind_mph = $2 * 1.1507771555;
            } else {
                $wind_mph = $m->WIND_MPH;
            }

            if($temp_f <= 40 && $wind_mph > 5) {
                # Do we have a wind chill?
                my $windchill = 35.74 + (0.6215 * $temp_f)
                                - 35.75 * ($wind_mph ** 0.16)
                                + 0.4275 * $temp_f * ($wind_mph ** 0.16);
                my $windchill_c = ($windchill - 32) * (5/9);
                push(@reply_with,
                    sprintf('a wind chill of %.1f°F (%.1f°C)',
                    $windchill, $windchill_c));
            }

            # Humidity, only if we have a dewpoint!
            if (defined $m->C_DEW) {
                my $humidity = 100 * ( ( (112 - (0.1 * $temp_c) + $m->C_DEW)
                             / (112 + (0.9 * $temp_c)) ) ** 8 );
                push(@reply_with, sprintf('%d', $humidity) . '% humidity');

                if($temp_f >= 80 && $humidity >= 40) {
                    # Do we have a heat index?

                    my $heatindex = - 42.379
                                    + 2.04901523 * $temp_f
                                    + 10.1433127 * $humidity
                                    - 0.22475541 * $temp_f * $humidity
                                    - 0.00683783 * $temp_f ** 2
                                    - 0.05481717 * $humidity ** 2
                                    + 0.00122874 * $temp_f ** 2 * $humidity
                                    + 0.00085282 * $temp_f * $humidity ** 2
                                    - 0.00000199 * $temp_f ** 2
                                                 * $humidity ** 2;

                    my $heatindex_c = ($heatindex - 32) * (5/9);
                    push(@reply_with,
                        sprintf('a heat index of %.1f°F (%.1f°C)',
                                $heatindex, $heatindex_c));
                }
            }
        } else {
            # We have no temp, "there are" (winds|skies)
            $reply .= ' there are ';
        }

        if($wind_mph) {
            my $tmp = int($wind_mph) . ' mph';
            if ($m->WIND_DIR_ENG) {
                $tmp .= ' winds from the ' . $m->WIND_DIR_ENG;
            } else {
                $tmp .= ' variable winds';
            }
            push(@reply_with, $tmp);
        }

        push(@reply_with, @{$m->WEATHER});
        my @sky = @{$m->SKY};
# Geo::METAR returns sky conditions that can't be plugged into sentences 
# nicely, let's clean them up.
        for(my $x=0;$x<=$#sky;$x++) {
            $sky[$x] = lc($sky[$x]);
            $sky[$x] =~ s/solid overcast/overcast/;
            $sky[$x] =~ s/sky clear/clear skies/;
            $sky[$x] =~ s/(broken|few|scattered) at/$1 clouds at/;
        }

        push(@reply_with, @sky);

        if($remarks) {
            # remarks are often not very easy to parse, but we can try.

            # Tornado and similar wx... I hope people don't rely on
            # simbot for tornado warnings.
            if($remarks =~ m/(TORNADO|FUNNEL CLOUD|WATERSPOUT)( (B|E(\d\d)?\d\d))?( (\d+) (N|NE|E|SE|S|SW|W|NW))?/) {
                my ($cond, $dist, $dir) = ($1, $5, $6);
                $cond = lc($cond);

                my $rmk = $cond;
                if($dist) { $rmk .= " $dist mi to the $dir"; }

                push(@reply_with, $rmk);
            }

            # Lightning.
            if($remarks =~ m/\b((OCNL|FRQ|CONS) )?LTG(CG|IC|CC|CA)*( (OHD|VC|DSNT))?( ([NESW\-]+))?\b/) {
                my ($freq, $loc, $dir) = ($2, $5, $7);
                my $rmk;

                if(defined $freq) {
                    $freq =~ s{OCNL}{occasional};
                    $freq =~ s{FRQ} {frequent};
                    $freq =~ s{CONS}{continuous};
                    $rmk = "$freq ";
                }

                if(defined $loc && $loc =~ m/DSNT/)
                    { $rmk .= 'distant '; }

                $rmk .= 'lightning';

                if(defined $loc) {
                    if($loc =~ /OHD/)   { $rmk .= ' overhead';          }
                    if($loc =~ /VC/)    { $rmk .= ' in the vicinity';   }
                }

                if(defined $dir)        { $rmk .= " to the $dir";       }

                push(@reply_with, $rmk);
            }

            # Thunderstorm.
            if($remarks =~ m/\bTS( VC)?( [NESW\-]+)?( MOV (N|NE|E|SE|S|SW|W|NW))?\b/) {
                my ($in_vc, $in_dir, $mov_dir) = ($1, $2, $4);
                my $rmk = 'thunderstorm ';
                if(defined $in_vc)      { $rmk .= 'in the vicinity ';   }
                if(defined $in_dir)     { $rmk .= "to the $in_dir ";    }
                if(defined $mov_dir)    { $rmk .= "moving $mov_dir";    }
                push(@reply_with, $rmk);
            }

            # Pressure rise/fall rapidly.
            if($remarks =~ m/\bPRES(R|F)R\b/) {
                push(@reply_with, 'pressure '
                    . ($1 eq 'R' ? 'rising' : 'falling')
                    . ' rapidly');
            }

            # Pressure trends.
            if($remarks =~ m/\b5(\d)(\d\d\d)\b/) {
                my ($trend, $change) = ($1, $2*.1);
                if($trend >= 0 && $trend <= 3) {
                    # change is positive or 0
                    if($change > 0) {
                        push(@reply_with, "pressure $change hPa higher than 3 hours ago");
                    }
                } elsif ($trend == 4) {
                    # no change
                } elsif ($trend >= 5 && $trend <= 8) {
                    # change is decreasing or 0
                    if($change > 0) {
                        push(@reply_with, "pressure $change hPa lower than 3 hours ago");
                    }
                }
            }

            # Snow increasing rapidly.
            if($remarks =~ m|SNINCR (\d+)/(\d+)|) {
                push(@reply_with,
                    "snow increasing rapidly ($1\" in last hr)");
            }
        }

        $reply .= shift(@reply_with);
        $reply .= ' with ' . join(', ', @reply_with) if @reply_with;
    }
    $reply .= '.';


    $reply =~ s/\bthunderstorm\b/t'storm/   if (length($reply)>430); #'

    &SimBot::send_message(&SimBot::option('network', 'channel'),
        "$nick: $reply");
}

sub got_xml {
    my ($kernel, $request_packet, $response_packet)
        = @_[KERNEL, ARG0, ARG1];
    my ($nick, $station)
        = (split(/!/, $request_packet->[1], 2));
    my $response = $response_packet->[0];

	# NOAA tries to be very helpful by offering a "did you mean?" list
	# returning an HTTP 300 response, instead of a 404 error.  This is
	# annoying when we are not a human being.  It also means we get an
	# HTTP 301 redirection if we have a similar METAR ID with only one
	# suitable alternative.  I have a feeling that if NOAA is trying to
	# give us a 3xx response, it'll be for a different report than the
	# user asked for, so we're going to trust the user knows what he
	# wants rather than letting NOAA's web server decide for him.
	if ($response->code eq '404' || $response->code =~ /^3/) {
		&SimBot::debug(3,
					   "weather: Couldn't get XML weather for $station; falling back to METAR.\n");
		my $url =
			'http://weather.noaa.gov/pub/data/observations/metar/stations/'
			. $station . '.TXT';
		my $request = HTTP::Request->new(GET=>$url);
		$kernel->post('wxua' => 'request', 'got_wx',
					  $request, "$nick!$station!0");
        return;
	} elsif ($response->is_error) {
		&SimBot::debug(3, "weather: Couldn't get XML weather for $station: " . $response->code . " " . $response->message . "\n");
		&SimBot::send_message(&SimBot::option('network', 'channel'), "$nick: " . CANNOT_ACCESS);
        return;
	}

    &SimBot::debug(4, 'weather: Got XML weather for ' . $nick
        . " for $station\n");
    my $raw_xml = $response->content;
	my $cur_obs;

	# If this XML feed is unparsable, METAR /may/ be more useful.
	# Hey, it sure beats die().
	if (!eval { $cur_obs = XMLin($raw_xml, SuppressEmpty => 1); }) {
		&SimBot::debug(3, "weather: XML parse error for $station; falling back to METAR.\n");
		&SimBot::debug(4, "weather: XML parser failure: $@");
		my $url =
			'http://weather.noaa.gov/pub/data/observations/metar/stations/'
			. $station . '.TXT';
		my $request = HTTP::Request->new(GET=>$url);
		$kernel->post('wxua' => 'request', 'got_wx',
					  $request, "$nick!$station!0");
		return;
	}

	my $u_time     = $cur_obs->{'observation_time'};
	my $location   = $cur_obs->{'location'};
	my $weather    = $cur_obs->{'weather'};
	my $temp       = $cur_obs->{'temperature_string'};
	my $rhumid     = $cur_obs->{'relative_humidity'};
	my $wdir       = $cur_obs->{'wind_dir'};
	my $wmph       = $cur_obs->{'wind_mph'};
	my $wgust      = $cur_obs->{'wind_gust_mph'};
	my $hidx       = $cur_obs->{'heat_index_string'};
	my $wchill     = $cur_obs->{'windchill_string'};
	my $visibility = $cur_obs->{'visibility'};

	my $msg = 'As reported ';
	my @reply_with;

	if(defined $u_time) {
        $u_time =~ s/Last Updated on //;
        $msg .= 'on ' . $u_time . ' ';
    }

    if(defined $location)   { $msg .= 'at ' . $location; }
    else                    { $msg .= 'at ' . $station; }

    if(defined $weather && $weather !~ m/^null$/i) {
        $weather = lc($weather);
        $weather =~ s/^\s*//;   # sometimes they have a space in front
        
        $weather =~ s/haze/hazy/;
        $weather =~ s/^(rain|snow)$/$1ing/;
        
        if   ($weather =~ m/not applicable|na/)
                { $msg .= ' it is '; }
        elsif($weather =~ m/ing$/)
                { $msg .= " it is $weather and "; }
        elsif($weather =~ m/^(a|patches of) /
              || $weather =~ m/showers/)
                { $msg .= " there are $weather and "; }
        elsif($weather =~ m/fog|smoke|rain|dust|sand/)
                { $msg .= " there is $weather and "; }
        
        else
                { $msg .= " it is $weather and "; }
    } else {
        $msg .= ' it is ';
    }
    
    if(defined $temp)       { $msg .= $temp; }

    $msg .= ', with';

    if(defined $hidx && $hidx !~ m/(Not Applicable|null)/i) {
        push(@reply_with, "a heat index of $hidx");
    }

    if(defined $wchill && $wchill !~ m/(Not Applicable|null)/i) {
        push(@reply_with, "a wind chill of $wchill");
    }

    if(defined $rhumid && $rhumid != 0) {
        push(@reply_with, "${rhumid}% humidity");
    }

    if(defined $wmph) {
        my $mmsg;
        $mmsg = "$wmph MPH winds from the $wdir";
        if(defined $wgust && $wgust > 0)
            { $mmsg .= " gusting to $wgust MPH"; }
        push(@reply_with, $mmsg);
    }

    if(defined $visibility && $visibility !~ m/(Not Applicable|null)/i) {
        push(@reply_with, "$visibility visibility");
    }

    my $sep;
    if($#reply_with == 1) {
        $sep = ' and ';
    } elsif($#reply_with > 1) {
        $sep = ', ';
        $reply_with[-1] = 'and ' . $reply_with[-1];
    }
    $msg .= ' ' . join($sep, @reply_with);

    &SimBot::send_message(&SimBot::option('network', 'channel'),
        "$nick: $msg");
}

sub nlp_match {
    my ($kernel, $nick, $channel, $plugin, @params) = @_;

	my $station;

	foreach (@params) {
		if (m/(\w+)\'s weather/i) { #'
			$station = $1;
		} elsif (m/(at|in|for) (\w+)/i) {
			$station = $2;
		} elsif (m/([A-Z]{4})/) {
			$station = $1;
		}
	}

	if (defined $station) {
		&new_get_wx($kernel, $nick, $channel, " weather", $station);
		return 1;
	} else {
		return 0;
	}
}

sub new_get_wx {
    my ($kernel, $nick, $channel, $command, $station) = @_;
    $kernel->post($session => 'do_wx', $nick, $station,
                            ($command =~ /^.metar$/ ? 1 : 0));
}

# Register Plugins
&SimBot::plugin_register(
						 plugin_id   => "weather",
						 plugin_desc => "Gets a weather report for the given station.",

						 event_plugin_call    => \&new_get_wx,
						 event_plugin_load    => \&messup_wx,
						 event_plugin_unload  => \&cleanup_wx,

						 event_plugin_nlp_call => \&nlp_match,
						 hash_plugin_nlp_verbs =>
						 ["weather", "rain", "snow", "windy", "hail",
						  "freez", "warm", "hot", "cold", "sleet"],
						 hash_plugin_nlp_formats =>
						 ["{at} {w}", "{for} {w}",
						  "{w}\'s weather", "{w4}"],
						 hash_plugin_nlp_questions =>
						 ["what-is", "how-is", "is-it", "command",
						  "i-want", "i-need", "how-about", "you-must"],
						 );

&SimBot::plugin_register(
						 plugin_id   => "metar",
						 plugin_desc => "Gives a raw METAR report for the given station.",

						 event_plugin_call   => \&new_get_wx,

						 );
