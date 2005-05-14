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
#   * find other postal codes -> lat/long databases so we can find the closest
#     station outside the US
#   * KILL Geo::METAR DAMN IT

package SimBot::plugin::weather;

use strict;
use warnings;

# The weather, more or less!
use Geo::METAR;

# the new fangled XML weather reports need to be parsed too!
use XML::Simple;

# and we need this to get the XML forecasts
use SOAP::Lite;

use POE;

# Fetching from URLs is better with LWP!
#use LWP::UserAgent;
# and even better with PoCo::Client::HTTP!
use POE::Component::Client::HTTP;
use HTTP::Request::Common qw(GET POST);
use HTTP::Status;

use DBI;    # for sqlite database

use Time::Local;

# declare globals
use vars qw( $session $dbh $postalcodes_dbh );

# These constants define the phrases simbot will use when responding
# to weather requests.
use constant STATION_LOOKS_WRONG =>
    q(That doesn't look like a METAR station. ); #'

use constant STATION_UNSPECIFIED =>
    'Please provide a METAR station ID. ';

use constant FIND_STATION_AT => 'You can look up station IDs at http://www.nws.noaa.gov/tg/siteloc.shtml .';

use constant CANNOT_ACCESS => 'Sorry; I could not access NOAA.';


use constant PI => 3.1415926;

# Flags
use constant USING_DEFAULTS     => 512;
use constant RAW_METAR          => 256;
#                               => 128;
use constant UNITS_METRIC       => 64;
use constant UNITS_IMPERIAL     => 32;
use constant UNITS_AUTO         => 16;
use constant NO_UNITS           => 8;
use constant DO_FORECAST        => 4;
use constant DO_CONDITIONS      => 2;
use constant DO_ALERTS          => 1;

# USING_DEFAULTS *MUST* be in DEFAULT_FLAGS, otherwise you'll get annoying
# error messages when things fail.
use constant DEFAULT_FLAGS      => USING_DEFAULTS | DO_CONDITIONS | UNITS_AUTO;

### cleanup_wx
# This method is run when SimBot is exiting. We save the station names
# cache here.
sub cleanup_wx {
    $dbh->disconnect;
    
    # We shouldn't have done anything to the zip codes DB, but just in case
    $postalcodes_dbh->rollback;
    $postalcodes_dbh->disconnect;
}

### messup_wx
# This method is run when SimBot is loading. We load the station names
# cache here. We also start our own POE session so we can wait for NOAA
# instead of giving up quickly so as to not block simbot
sub messup_wx {
    # let's create our database
    $dbh = DBI->connect('dbi:SQLite:dbname=data/weather','','',
        { RaiseError => 1, AutoCommit => 0 }) or die;
    
    $postalcodes_dbh = DBI->connect('dbi:SQLite:dbname=data/postalcodes','','',
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
    longitude REAL
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
            got_metar       => \&got_metar,
            get_alerts      => \&get_alerts,
            got_alerts      => \&got_alerts,
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
}

### do_wx
# this is called when POE tells us someone wants weather
sub do_wx {
    my  ($kernel, $nick, $location, $flags) =
      @_[KERNEL,  ARG0,  ARG1,     ARG2];

    &SimBot::debug(3, 'weather: Received request from ' . $nick
        . " for $location\n");

    # So, what are we doing?
    unless($flags & DO_CONDITIONS
        || $flags & DO_ALERTS || $flags & DO_FORECAST)
    {
        &SimBot::send_message(&SimBot::option('network', 'channel'),
            "$nick: Sorry, something unexpected happened. This has been logged; please try again later.");
        &SimBot::debug(1, "weather: in do_wx with nothing to do!\n");
        return;
    }
    
    my($station, $postalcode, $lat, $long, $state, $geocode);
    
    if   ($location =~ /^\d{5}$/)       { $postalcode = $location; } # US
    elsif($location =~ /^([A-Z]{1,2}[0-9]{1,2}[A-Z]?)(?: [0-9][A-Z]{2})?$/)
                                        { $postalcode = $1; } # UK
    elsif($location =~ /^[A-Z0-9]{4}$/i) { $station = $location; }
    
    
    # OK, now we know what location specification the user gave us.
    # now let's try to figure out the other location information
    if(defined $station) {
        # try to get lat/long/state from the station
        my $query = $dbh->prepare_cached(
            'SELECT latitude, longitude, state FROM stations'
            . ' WHERE id = ? LIMIT 1'
        );
        $query->execute($station);
        ($lat, $long, $state) = $query->fetchrow_array;
        $query->finish;
        
        # FIXME: OK, now try to get the geocode from the lat/long
        # (find nearest zip, use it's geocode)
        # this would allow %weather kbdl forecast to work
    }
    if(defined $postalcode) {
        # try to get lat/long/state/geocode from the postalcode db
        my $query = $postalcodes_dbh->prepare_cached(
            'SELECT latitude, longitude, state, geocode FROM postalcodes'
            . ' WHERE code = ? LIMIT 1'
        );
        $query->execute($postalcode);
        ($lat, $long, $state, $geocode) = $query->fetchrow_array;
        $query->finish;
    }
    
    if(defined $postalcode && !defined $station) {
        $station = &find_closest_station($postalcode);
    }
    
    # OK, we have all the locations we're gonna get.
    # Now let's try to do what we were asked to
    
    if($flags & DO_ALERTS) {
        if(defined $state && defined $geocode) {
            $kernel->post($session => 'get_alerts', $nick, $lat, $long, $state, $geocode, $flags);
        } elsif(!($flags & USING_DEFAULTS)) {
            # If we don't have enough information to do the forecast or
            # alerts, only complain if we aren't using the default options.
            &SimBot::send_message(&SimBot::option('network', 'channel'),
                "$nick: Sorry, but I have no forecast for that location.");
        }
    }
    
    if($flags & DO_CONDITIONS && defined $station) {
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
        my $url =
            'http://weather.noaa.gov/pub/data/observations/metar/stations/'
            . $station . '.TXT';
        my $request = HTTP::Request->new(GET=>$url);
        $kernel->post('wxua' => 'request', 'got_metar',
                                $request, "$nick!$station!$flags");
    }
    
    if($flags & DO_FORECAST && defined $lat) {
        # Right now, forecast is handled as part of alerts.
        # FIXME: This should change.
    }
}

sub got_metar {
    # This parses METAR reports.
    # This should be replaced with something.
    # Either stop using Geo::METAR, or find some service that gives
    # us XML reports like NOAA does for US stations.
    
    my ($kernel, $request_packet, $response_packet)
        = @_[KERNEL, ARG0, ARG1];
    my ($nick, $station, $flags)
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

    &SimBot::debug(4, "weather: METAR is " . $raw_metar . "\n");

    my $station_name_query = $dbh->prepare_cached(
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
    $station_name_query->finish;
    
    if($flags & RAW_METAR) {
        &SimBot::send_message(&SimBot::option('network', 'channel'),
            "$nick: METAR report for $station_name is $raw_metar.");
        return;
    }
    
    
    # Geo::METAR has issues not ignoring the remarks section of the
    # METAR report. Let's strip it out.
    my $remarks;
    ($raw_metar, undef, $remarks)
        = $raw_metar =~ m/^(.*?)( RMK (.*))?$/;
    $raw_metar =~ s|/////KT|00000KT|;
    $raw_metar =~ s{\b(BLU|WHT|GRN|YLO|AMB|RED)\b}{};
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
    my $wind_mph;

	$m->{date_time} =~ m/(\d\d)(\d\d)(\d\d)Z/;
	my $time = "$2:$3";
	my $day=$1;

    my $reply = "As reported at $time UTC at $station_name";
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

            push(@reply_with, &temp($temp_c, 'C', $flags));

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

                push(@reply_with, 'a wind chill of '
                    . &temp($windchill, 'F', $flags));
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

                    push(@reply_with, 'a heat index of '
                        . &temp($heatindex, 'F', $flags));
                }
            }
        } else {
            # We have no temp, "there are" (winds|skies)
            $reply .= ' there are ';
        }

        if($wind_mph) {
            my $tmp = &speed($wind_mph, 'MPH', $flags);
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
                if($dist) { $rmk .= &dist($dist, 'mi', $flags)
                                . " to the $dir"; }

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

sub got_alerts {
    my ($kernel, $request_packet, $response_packet)
        = @_[KERNEL, ARG0, ARG1];
    my ($nick, $lat, $long, $geocode, $flags)
        = (split(/!/, $request_packet->[1], 5));
    my $response = $response_packet->[0];
    
    if(!defined $flags) {
        my @caller = caller(1);
        warn "get_forecast called with no flags from $caller[3] line $caller[2]";
    }
    
    if ($response->is_error) {
        # The server isn't being nice to us.
        # Let's just move on to getting the forecast
        &SimBot::send_message(&SimBot::option('network', 'channel'),
            "$nick: " . &get_forecast($nick, $lat, $long, $flags));
        return;
    }
    my $raw_xml = $response->decoded_content;
    
    my $cap_alert;
    
    if (!eval { $cap_alert = XMLin($raw_xml, NormaliseSpace => 2, ForceArray => ['cap:info']); }) {
		&SimBot::debug(3, "weather: XML parse error for alerts\n");
		&SimBot::debug(4, "weather: XML parser failure: $@");

        # Bad XML! Let's just move on to getting the forecast.
        &SimBot::send_message(&SimBot::option('network', 'channel'),
            "$nick: " . &get_forecast($nick, $lat, $long, $flags));

		return;
	}

    my @alerts;
    my @alerts_link;
    
    
    foreach my $cur_cap_info (@{$cap_alert->{'cap:info'}}) {
        if(defined $cur_cap_info->{'cap:area'}->{'cap:geocode'}
            && $cur_cap_info->{'cap:area'}->{'cap:geocode'} == $geocode)
        {
            # We have a warning!
            push(@alerts,      $cur_cap_info->{'cap:event'});
            push(@alerts_link, $cur_cap_info->{'cap:web'});
        }
    }

    if(@alerts) {
        if($#alerts == 0) {
            &SimBot::send_message(&SimBot::option('network', 'channel'),
                "$nick: $alerts[0] $alerts_link[0]");
        } else {
            # more than one alert, we should do something a bit nicer...
            &SimBot::send_message(&SimBot::option('network', 'channel'),
                "$nick: " . join (', ', @alerts));
        }
    }
    # OK, we're done with the alerts... now do the forecast
    &SimBot::send_message(&SimBot::option('network', 'channel'),
        "$nick: " . &get_forecast($nick, $lat, $long, $flags));
}

sub get_forecast {
    my ($nick, $lat, $long, $flags) = @_;
    
    if(!defined $flags) {
        my @caller = caller(1);
        warn "get_forecast called with no flags from $caller[3] line $caller[2]";
        $flags = UNITS_IMPERIAL;
    }
    
    if(! ($flags & UNITS_IMPERIAL || $flags & UNITS_METRIC)) {
        # Trying to provide both units is fugly.
        $flags |= UNITS_IMPERIAL;
    }
    
    my $serviceURI = 'http://weather.gov/forecasts/xml';
    my $method = 'NDFDgenByDay';
    my $endpoint = "$serviceURI/SOAP_server/ndfdXMLserver.php";
    my $soapAction = "$serviceURI/DWMLgen/wsdl/ndfdXML.wsdl#$method";

    my $numDays = 7;
    my $format = '24 hourly';
    
    my @time = localtime;
    
    my $startDate = sprintf('%04d-%02d-%02d',
        ($time[5] + 1900), ($time[4] + 1), ($time[3]));
        
    my $weather = SOAP::Lite->new(uri => $soapAction,
                                proxy => $endpoint);
    $weather->transport->timeout(8);
    my $response;
    if(!eval {
        $response = $weather->call(
            SOAP::Data->name($method)
                => SOAP::Data->type(decimal => $lat      )->name('latitude'),
                => SOAP::Data->type(decimal => $long     )->name('longitude'),
                => SOAP::Data->type(date    => $startDate)->name('startDate'),
                => SOAP::Data->type(integer => $numDays  )->name('numDays'),
                => SOAP::Data->type(string  => $format   )->name('format')
        );
    }) {
        return 'I cannot contact NOAA. Please try again later.';
    }
    
    if ($response->fault) {
         return 'Something unexpected happened: ' . $response->faultstring;
    } else {
#        open(OUT, ">forecast_debug");
#        print OUT $response->result;
        
        my $xml = $response->result;
        
        my $forecast;
        if (!eval { $forecast = XMLin($xml, KeyAttr=>['type']); }) {
            return 'The forecast could not be parsed. Blame NOAA.';
        }
        
        my ($maxperiodkey, $minperiodkey, $condsperiodkey);
        my @days;
        
        # Find the time layout we care about. This is certainly not the
        # Right Way, and if forecast ever breaks, suspect this.
        # (We really should be reading in all the time layouts, and reference
        # them against the data we care about to find the right one)
        foreach my $cur_time_layout (@{$forecast->{'data'}->{'time-layout'}}) {
            if($cur_time_layout->{'layout-key'} =~ m/k-p24h-n\d-1/) {
                @days = @{$cur_time_layout->{'start-valid-time'}};
                last;
            }
        }
        
        my (undef, undef, undef, $today_day, $today_mon, $today_year, $toay_wday) = localtime;
        foreach (@days) {
            my ($year, $month, $day) = m/^(\d+)-(\d+)-(\d+)/;
            if($year == $today_year+1900
                && $month == $today_mon+1
                && $day == $today_day)
            {
                $_ = 'Today';
            } else {
                my $wday = (localtime(timelocal(undef, undef, undef, $day, $month-1, $year-1900)))[6];
                $_ = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat')[$wday];
            }
        }
        
        my (@temp_highs, @temp_lows, $temp_highs_unit, $temp_lows_unit);
        my $temp_key = $forecast->{'data'}->{'parameters'}->{'temperature'};
        
        @temp_highs = @{$temp_key->{'maximum'}->{'value'}};
        $temp_highs_unit = $temp_key->{'maximum'}->{'units'};
        @temp_lows = @{$temp_key->{'minimum'}->{'value'}};
        $temp_lows_unit = $temp_key->{'minimum'}->{'units'};

        my @conditions;
        foreach my $cur_weather_conditions (@{$forecast->{'data'}->{'parameters'}->{'weather'}->{'weather-conditions'}}) {
            push(@conditions, $cur_weather_conditions->{'weather-summary'});
        }
        
        my $msg;
        for my $i (0 .. $#days) {
            my $cur_msg = "%bold%$days[$i]%bold%: ";
            
            if($conditions[$i]) { $cur_msg .= $conditions[$i] . ', '; }
            if($temp_highs[$i] && $temp_lows[$i]
                && $temp_highs[$i] !~ /^HASH/
                && $temp_lows[$i] !~ /^HASH/)
            {
                $cur_msg .= &temp($temp_highs[$i], $temp_highs_unit, $flags | NO_UNITS) . '/' . &temp($temp_lows[$i], $temp_lows_unit, $flags);
            } elsif($temp_highs[$i] && $temp_highs[$i] !~ /^HASH/) {
                $cur_msg .= 'high ' . &temp($temp_highs[$i], $temp_highs_unit, $flags);
            } elsif($temp_lows[$i] && $temp_lows[$i] !~ /^HASH/) {
                $cur_msg .= 'low ' . &temp($temp_lows[$i], $temp_lows_unit, $flags);
            }
            $cur_msg .= '; ';
            $msg .= $cur_msg;
        }
        $msg =~ s/; $//;
        return &SimBot::parse_style($msg);
    }
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
		&handle_user_command($kernel, $nick, $channel, " weather", $station);
		return 1;
	} else {
		return 0;
	}
}

sub handle_user_command {
    my ($kernel, $nick, $channel, $command, $station, @args) = @_;
    my $flags = 0;
    
    my ($lat, $long, $state, $geocode);
    if($station =~ /f(ore)?cast/) {
        if(@args) {
            $station = shift(@args);
            $flags &= ~DO_CONDITIONS;
            $flags |= DO_FORECAST | DO_ALERTS;
        } else {
            &SimBot::send_message($channel, "$nick: For what US ZIP code do you want a forecast?");
            return;
        }
    }
    
    if($command =~ /^.metar$/)      { $flags |= RAW_METAR | DO_CONDITIONS; }
    foreach(@args) {
        if(m/^m(etric)?$/)          { $flags |= UNITS_METRIC; }
        if(m/^f(ore)?cast$/)        { $flags |= DO_FORECAST | DO_ALERTS; }
        if(m/^(us|imp(erial)?)$/)   { $flags |= UNITS_IMPERIAL; }
        if(m/^raw$/)                { $flags |= RAW_METAR | DO_CONDITIONS; }
        if(m/^cond(itions)?/)       { $flags |= DO_CONDITIONS; }
    }
    if($flags == 0
        || $flags == UNITS_METRIC
        || $flags == UNITS_IMPERIAL)
    {
        $flags |= DEFAULT_FLAGS;
    }
    $kernel->post($session => 'do_wx', $nick, $station, $flags);
}

sub get_alerts {
    my  ($kernel, $nick, $lat, $long, $state, $geocode, $flags) =
      @_[KERNEL,  ARG0,  ARG1, ARG2,  ARG3,   ARG4,     ARG5  ];
    
    &SimBot::debug(3, 'weather: Received forecast request from ' . $nick
        . " for $lat $long $geocode, in get_alerts\n");
    
    my $url = 'http://weather.gov/alerts/' . lc($state) . '.cap';
    my $request = HTTP::Request->new(GET => $url);
    $request->header('Accept-Encoding' => 'gzip, deflate');
    $kernel->post('wxua' => 'request', 'got_alerts',
                    $request, "$nick!$lat!$long!$geocode!$flags");
                    
    # We're done here - got_alerts will handle requesting the forecast
}

sub find_closest_station {
    my ($zipcode) = @_;
    
    # OK, we need the lat/long for that zip code.
    my $query = $postalcodes_dbh->prepare_cached(
        'SELECT latitude, longitude FROM postalcodes WHERE code = ?'
    );
    $query->execute($zipcode);
    my ($zip_lat, $zip_long) = $query->fetchrow_array;
    
    $query->finish;
    
    # OK, now we need to find potential stations.
    $query = $dbh->prepare_cached(
        'SELECT id, latitude, longitude FROM stations'
        . ' WHERE latitude BETWEEN ? AND ?'
        . ' AND longitude BETWEEN ? AND ?');
        
    $query->execute($zip_lat - 1, $zip_lat + 1,
                                $zip_long - 1, $zip_long + 1);
                                
    my $nearest_station;
    my $nearest_dist;
    while(my ($cur_station, $cur_lat, $cur_long) = $query->fetchrow_array) {
        my $theta = $cur_long - $zip_long;
        my $dist = rad2deg(acos(
                        sin(deg2rad($cur_lat)) * sin(deg2rad($zip_lat))
                        + cos(deg2rad($cur_lat)) * cos(deg2rad($zip_lat)) * cos(deg2rad($theta))
                        )) * 60 * 1.1515;
                    
        if(!defined $nearest_station || $nearest_dist > $dist) {
            $nearest_station = $cur_station;
            $nearest_dist = $dist;
        }
    }

    return $nearest_station;
}

sub dms_to_degrees {
    my ($degrees, $minutes, $seconds, $dir) = @_;
    
    if(defined $minutes)    { $degrees += $minutes * 0.0166666667; }
    if(defined $seconds)    { $degrees += $seconds * 0.000277777778; }
    
    if(defined $dir && $dir =~ m/[SW]/) { $degrees = $degrees * -1; }
    
    return $degrees;
}

sub acos {
    my ($rad) = @_;
    return(atan2(sqrt(1 - $rad**2), $rad));
}

sub deg2rad {
    my ($deg) = @_;
    return ($deg * PI / 180);
}

sub rad2deg {
    my ($rad) = @_;
    return ($rad * 180 / PI);
}

sub temp {
    my ($temp, $unit, $flags) = @_;
    if(!defined $unit
        || $unit !~ m/C|F/i)
    {
        my @caller = caller(1);
        warn "unit missing or invalid in temp, called from $caller[3] line $caller[2]";
        return $temp;
    }
    
    if(    ($unit =~ s/^C.*$/C/i && $flags & UNITS_METRIC)
        || ($unit =~ s/^F.*$/F/i && $flags & UNITS_IMPERIAL))
    {
        # Temperature is already in the desired units.
        return (int $temp) . ($flags & NO_UNITS ? '' : '°' . $unit);
    }
    
    my ($temp_c, $temp_f);
    if($unit =~ /C/i) {
        $temp_c = $temp;
        $temp_f = $temp * 1.8 + 32;
    } elsif($unit =~ /F/i) {
        $temp_f = $temp;
        $temp_c = ($temp - 32) * (5/9);
    }
        
    if($flags & UNITS_METRIC) {
        return (int $temp_c)
            . ($flags & NO_UNITS ? '' : '°C');
    }
    
    if($flags & UNITS_IMPERIAL) {
        return (int $temp_f)
            . ($flags & NO_UNITS ? '' : '°F');
    }
    
    return (int $temp_f) . ($flags & NO_UNITS ? '' : '°F')
    . ' (' . (int $temp_c) . ($flags & NO_UNITS ? '' : '°C') . ')';
}

sub speed {
    my ($speed, $unit, $flags) = @_;
    
    if(!defined $unit
        || $unit !~ m(kt|km/h|mph)i)
    {
        my @caller = caller(1);
        warn "unit missing or invalid in speed, called from $caller[3] line $caller[2]";
        return $speed;
    }
    
    if($unit =~ m(mph)) { $unit = 'MPH'; }
    
    if(    ($unit =~ m(km/h)i && $flags & UNITS_METRIC)
        || ($unit =~ m(MPH)i  && $flags & UNITS_IMPERIAL))
    {
        return (int $speed) . ($flags & NO_UNITS ? '' : ' ' . $unit);
    }
    
    my ($speed_kmh, $speed_mph);
    if($unit =~ /kt/i) {
        $speed_kmh = 1.85325 * $speed;
        $speed_mph = 1.15155 * $speed;
    } elsif($unit =~ /MPH/i) {
        $speed_kmh = 1.609344 * $speed;
        $speed_mph = $speed;
    } elsif($unit =~ m(km/h)i) {
        $speed_kmh = $speed;
        $speed_mph = 0.621371;
    }
    
    if($flags & UNITS_METRIC) {
        return (int $speed_kmh) . ($flags & NO_UNITS ? '' : ' km/h');
    }
    
    if($flags & UNITS_IMPERIAL) {
        return (int $speed_mph) . ($flags & NO_UNITS ? '' : ' MPH');
    }
    return (int $speed_mph) . ($flags & NO_UNITS ? '' : ' MPH'). ' (' . (int $speed_kmh) . ($flags & NO_UNITS ? '' : ' km/h') . ')';
}

sub distance {
    my ($dist, $unit, $flags) = @_;
    if(!defined $unit
        || $unit !~ m/mi|km/i)
    {
        my @caller = caller(1);
        warn "unit missing or invalid in distance, called from $caller[3] line $caller[2]";
        return $dist;
    }
        if(    ($unit =~ m/km/i && $flags & UNITS_METRIC)
            || ($unit =~ m/mi/i && $flags & UNITS_IMPERIAL))
    {
        # Distance is already in the desired units.
        return (int $dist) . ($flags & NO_UNITS ? '' : ' ' . $unit);
    }
    
    my ($dist_mi, $dist_km);
    if($unit =~ /km/i) {
        $dist_km = $dist;
        $dist_mi = $dist * 1.609344;
    } elsif($unit =~ /mi/i) {
        $dist_mi = $dist;
        $dist_km = $dist * 0.621371192;
    }
        
    if($flags & UNITS_METRIC) {
        return (int $dist_km)
            . ($flags & NO_UNITS ? '' : ' km');
    }
    
    if($flags & UNITS_IMPERIAL) {
        return (int $dist_mi)
            . ($flags & NO_UNITS ? '' : ' mi');
    }
    
    return (int $dist_mi) . ($flags & NO_UNITS ? '' : ' mi')
    . ' (' . (int $dist_km) . ($flags & NO_UNITS ? '' : ' km') . ')';
}

# Register Plugins
&SimBot::plugin_register(
						 plugin_id   => "weather",
				         plugin_params => "(<station ID|zip|postal code> [metar|raw] [metric|us] | forecast <zip>)",
						 plugin_help =>
"Gets a weather report for the given station, zip, or postal code.\nSpecifying %bold%metar%bold% will force the parsing the metar report instead of using the NOAA XML data.\nSpecifying %bold%raw%bold% will show the METAR report in its original form.\nforecast <zip> will get the forecast for that US zip code.",

						 event_plugin_call    => \&handle_user_command,
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
						 plugin_params => "<station ID>",
						 plugin_help => "Gives a raw METAR report for the given station.",

						 event_plugin_call   => \&handle_user_command,

						 );

