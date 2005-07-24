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

package SimBot::plugin::weather;

use strict;
use warnings;

# the new fangled XML weather reports need to be parsed!
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

our %cond_names = (
    'MI', 'shallow',
    'PR', 'partial',
    'BC', 'patches',
    'DR', 'low drifting',
    'BL', 'blowing',
    'SH', 'showers',
    'TS', 'thunderstorm',
    'FZ', 'freezing',
    
    'DZ', 'drizzle',
    'RA', 'rain',
    'SN', 'snow',
    'SG', 'snow grains',
    'IC', 'ice crystals',
    'PL', 'ice pellets',
    'GR', 'hail',
    'GS', 'small hail and/or snow pellets',
    'UP', 'unknown precipitation',
    
    'BR', 'mist',
    'FG', 'fog',
    'FU', 'smoke',
    'VA', 'volcanic ash',
    'DU', 'widespread dust',
    'SA', 'sand',
    'HZ', 'haze',
    'PY', 'spray',
    
    'PO', 'well-developed dust/sand whirls',
    'SQ', 'squalls',
    'FC', 'funnel cloud/tornado/waterspout',
    'SS', 'sandstorm',
);


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
        #my $url =
        #    'http://weather.noaa.gov/pub/data/observations/metar/stations/'
        #    . $station . '.TXT';
        #my $request = HTTP::Request->new(GET=>$url);
        $kernel->post('wxua' => 'request', 'got_metar',
            (POST 'http://adds.aviationweather.noaa.gov/metars/index.php',
             Content_Type => 'form-data',
             Content    => [
                station_ids => $station,
                std_trans => 'standard',
                chk_metars => 'on',
                hoursStr => 'most recent only',
                submitmet => 'Submit',
            ],
           ), "$nick!$station!$flags");
    }
    
    if($flags & DO_FORECAST && defined $lat) {
        # Right now, forecast is handled as part of alerts.
        # FIXME: This should change.
    }
}

sub got_metar {
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
#    my ($datestamp, $raw_metar) = split(/\n/, $response->content);
    my $raw_metar;
    if($response->content =~ m|no data available|) {
        &SimBot::send_message(&SimBot::option('network', 'channel'),
            "$nick: Sorry, there is no report available for \"$station\". "
            . FIND_STATION_AT);
        return;
    }
    unless(($raw_metar) = $response->content =~ m|<FONT FACE="Monospace,Courier">(.*?)</FONT>|s) {
        &SimBot::debug(1, "NOAA made no sense. They said:\n" . $response->content . "\n");
        &SimBot::send_message(&SimBot::option('network', 'channel'), "$nick: I couldn't make sense of what NOAA told me.");
        return;
    }
    $raw_metar =~ s/\s+/ /ig;
    
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
    
    #my $wxhash = &parse_metar("${datestamp}\n${raw_metar}");
    my $wxhash = &parse_metar($raw_metar);
    
    my $remarks;
    ($raw_metar, undef, $remarks)
        = $raw_metar =~ m/^(.*?)( RMK (.*))?$/;

    # Let's form a response!
    if (!defined $wxhash->{report_time}) {
        # Something is very weird about this METAR.  It has no date,
        # so we are probably not going to get anything useful out of
        # it.
        &SimBot::send_message(&SimBot::option('network', 'channel'),
            "$nick: The METAR report for $station_name didn't make any sense to me.  Try "
                . &SimBot::option('global', 'command_prefix')
                . "metar $station if you want to try parsing it yourself.");
        return;
    }
    my ($wind_mph, $temp_f, $temp_c);
    
    my $reply = 'As reported ';
    if(defined $wxhash->{'report_time'}->{'unixtime'}) {
        $reply .= &SimBot::timeago($wxhash->{'report_time'}->{'unixtime'}, 1);
    } else {
        $reply .= sprintf('at %d:%02d',
            $wxhash->{'report_time'}->{'hour'},
            $wxhash->{'report_time'}->{'minute'})
            . ' ' . $wxhash->{'report_time'}->{'timezone'};
    }
    $reply .= " at $station_name";
    my @reply_with;

    # There's no point in this exercise unless there's data in there
    if ($raw_metar =~ /NIL$/) {
        $reply .= " there is no data available";
    } else {        
        # Temperature and related details *only* if we have
        # a temperature!
        if (defined $wxhash->{'temperature'}) {
            # We have a temp, "it is"
            $reply .= " it is ";

            push(@reply_with, &temp($wxhash->{'temperature'}->{'value'},
                                    $wxhash->{'temperature'}->{'unit'},
                                    $flags));
            $temp_f = &temp($wxhash->{'temperature'}->{'value'},
                            $wxhash->{'temperature'}->{'unit'},
                            UNITS_IMPERIAL | NO_UNITS);
            $temp_c = &temp($wxhash->{'temperature'}->{'value'},
                            $wxhash->{'temperature'}->{'unit'},
                            UNITS_METRIC | NO_UNITS);
                            
            if(defined $wxhash->{'wind_speed'}) {
                $wind_mph = &speed($wxhash->{'wind_speed'}->{'value'},
                                   $wxhash->{'wind_speed'}->{'unit'},
                                   UNITS_IMPERIAL | NO_UNITS);
                                   
                if($temp_f <= 40 && $wind_mph > 5) {
                    # Do we have a wind chill?
                    my $windchill = 35.74 + (0.6215 * $temp_f)
                                    - 35.75 * ($wind_mph ** 0.16)
                                    + 0.4275 * $temp_f * ($wind_mph ** 0.16);
                
                    push(@reply_with, 'a wind chill of '
                        . &temp($windchill, 'F', $flags));
                }
            }

            # Humidity, only if we have a dewpoint!
            if (defined $wxhash->{'dew_point'}) {
                my $humidity = 100 * ( ( (112 - (0.1 * $temp_c) +
                    &temp($wxhash->{'dew_point'}->{'value'},
                          $wxhash->{'dew_point'}->{'unit'},
                          UNITS_METRIC | NO_UNITS))
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

        if(defined $wxhash->{'wind_speed'}
                && $wxhash->{'wind_speed'}->{'value'} > 0) {
            my $tmp = &speed($wxhash->{'wind_speed'}->{'value'},
                             $wxhash->{'wind_speed'}->{'unit'},
                             $flags);
            if (defined $wxhash->{'wind_dir'}) {
                $tmp .= ' winds from the ' . &deg_to_compass($wxhash->{'wind_dir'}->{'value'});
            } else {
                $tmp .= ' variable winds';
                # FIXME: Deal with wind_dir_range
            }
			if (defined $wxhash->{'wind_gust'}) {
				$tmp .= ' gusting to '
				    . &speed($wxhash->{'wind_gust'}->{'value'},
				             $wxhash->{'wind_gust'}->{'unit'},
				             $flags);
			}
            push(@reply_with, $tmp);
        }

        if(defined $wxhash->{'sky_conditions'}) {
            push(@reply_with, @{$wxhash->{'sky_conditions'}});
        }


        # Captains may care about every single layer of cloud cover, but
        # we don't. Let's find the worst.
        my $worst_clouds = 'fair skies';
        foreach my $cur_cloud (@{$wxhash->{'cloud_conditions'}}) {
            my $cover = $cur_cloud->{'cover'};
            if(   ($worst_clouds =~ m/fair skies|few/)
               || ($worst_clouds =~ m/scattered/ && $cover =~ m/broken|overcast/)
               || ($worst_clouds =~ m/broken/ && $cover =~ m/overcast/) ) {
                
                $worst_clouds = $cover;
            }
            if($worst_clouds =~ m/overcast/) {
                # we've found the worst cover, no need to keep looking
                last;
            }
        }
        
        if($worst_clouds !~ m/fair skies/ || !defined $wxhash->{'sky_conditions'}) {
            if($worst_clouds !~ m/overcast|fair/) {
                $worst_clouds .= ' clouds';
            }
            push(@reply_with, $worst_clouds);
        }
        
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
            if($year <= 2000) {
	        # NOAA's giving us bogus data again
		&SimBot::debug(1, "weather: Forecast is in the past, check your clock!\n");
		return 'Could not get the forecast.';
            } elsif($year == $today_year+1900
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


sub parse_metar {
    my $raw_input = $_[0];
    
    my %timedate;
    if($raw_input =~ m/\n/) {
        # probably came from NOAA and has a nicer date stamp on the first line
        # Let's use it.
        my $date;
        ($date, $raw_input) = split(/\n/, $raw_input, 2);
        ($timedate{'year'}, $timedate{'month'}, $timedate{'day'}, $timedate{'hour'}, $timedate{'minute'}) = $date =~
            m|(\d{4})/(\d{2})/(\d{2}) (\d{2}):(\d{2})|;
            
        foreach(($timedate{'year'}, $timedate{'month'}, $timedate{'day'}, $timedate{'hour'}, $timedate{'minute'})) {
            $_ = int $_;
        }
        $timedate{'timezone'} = 'UTC';
        $timedate{'unixtime'} = timegm(0, $timedate{'minute'}, $timedate{'hour'}, $timedate{'day'}, $timedate{'month'} - 1, $timedate{'year'});
    }
    my @metar = split(/ /, $raw_input);
    
    my %weather_data;
    my @cloud_conds;
    my @sky_conds;
    my @unknown_blocks;
    my @unknown_remarks;
    
    while(my $cur_block = shift @metar) {
        if($cur_block =~ m/^(METAR|TAF|SPECI)$/) {                  # TYPE
            # METAR type. We don't usually see this, but it's here
            # for completeness.
            $weather_data{'report_type'} = $1;
            
            
        } elsif($cur_block =~ m/^([A-Z]{4})$/
                && !defined $weather_data{'station_id'}) {          # ID
            # Station ID
            $weather_data{'station_id'} = $1;
            
            
        } elsif($cur_block =~ m/^(\d{2})(\d{2})(\d{2})Z$/) {        # DAY/TIME
            $timedate{'day'} = int $1;
            $timedate{'hour'} = int $2;
            $timedate{'minute'} = int $3;
            $timedate{'timezone'} = 'UTC';
            
            
        } elsif($cur_block =~ m/^(\d{3}|VRB|GRID\d{3})(\d{2})(?:G(\d{2}))?KT$/) { # WIND
            # dddss[Ggg]KT
            # ddd dir in degrees
            # ss speed in knots
            # gg gust speed in knots
            # -- OR --
            # GRIDxxxss[Ggg]KT
            # xxx some direction specification I've only seen used at the
            #   south pole
            
            my ($dir, $speed, $gust) = ($1, $2, $3);
            
            if($dir =~ m/^VRB$/) {
                $weather_data{'wind_dir'}->{'variable'} = 1;
            } elsif($1 =~ m/^GRID/) {
                # hard code the south pole's odd wind speed direction
                if($weather_data{'station_id'} =~ m/^NZSP$/) {
                    $weather_data{'wind_dir'} = &make_value_unit(0, 'deg');
                }
            } else {
                $weather_data{'wind_dir'} = &make_value_unit(int $dir, 'deg');
            }
            $weather_data{'wind_speed'} = &make_value_unit(int $speed, 'kt');
                if(defined $gust) {
                $weather_data{'wind_gust'} = &make_value_unit(int $gust, 'kt');
            }
            
            
        } elsif($cur_block =~ m/^(\d{3})V(\d{3})$/) {               # WIND VAR
            # variable direction range for wind speeds over 6 kt
            $weather_data{'wind_dir_range'} = [&make_value_unit(int $1, 'deg'), &make_value_unit(int $2, 'kt')];
            
            
        } elsif($cur_block =~ m/^(\d{1,5})SM$/) {                   # VISIBILITY
            $weather_data{'visibility'} = &make_value_unit(int $1, 'mi');
            
            
        } elsif($cur_block =~ m|^(?:(M)?(\d{2}))/(?:(M)?(\d{2}))?$|) {# TEMP
            if(defined $2) {
                my $temp = int $2;
                $temp *= -1 if defined $1;
                $weather_data{'temperature'} = &make_value_unit($temp, 'C');
            }
            
            if(defined $4) {
                my $temp = int $4;
                $temp *= -1 if defined $3;
                $weather_data{'dew_point'} = &make_value_unit($temp, 'C');
            }
            
            
        } elsif($cur_block =~ m/^A(\d{4})$/) {                      # PRESSURE
            $weather_data{'pressure'} = &make_value_unit((int $1) / 100, 'inHg');
            
            
        } elsif($cur_block =~ m{^                                   # WX COND
                (-|\+|VC)?                      # Intensity
                (MI|PR|BC|DR|BL|SH|TS|FR)?      # Descriptor
                (DZ|RA|SN|SG|IC|PL|GR|GS|UP)?   # Precipitation
                (BR|FG|FU|VA|DU|SA|HZ|PY)?      # Obscuration
                (PO|SQ|FC|SS)?                  # Other
                $}x) {
            my ($intensity, $descriptor, $precip, $obscuration, $other)
                = ($1,$2,$3,$4,$5);
            my @cond;
            
            if(defined $intensity) {
                if($intensity =~ m/^-$/) {
                    push(@cond, 'light');
                } elsif($intensity =~ m/^\+$/) {
                    push(@cond, 'heavy');
                }
            }
            
            if(defined $descriptor && $descriptor !~ m/^SH$/) {
                push(@cond, $cond_names{$descriptor});
            }
            
            if(defined $precip) {
                push(@cond, $cond_names{$precip});
            }
            if(defined $obscuration) {
                push(@cond, $cond_names{$obscuration});
            }
            if(defined $other) {
                push(@cond, $cond_names{$other});
            }
            
            if(defined $descriptor && $descriptor =~ m/^SH$/) {
                push(@cond, $cond_names{'SH'});
            }
            
            push(@sky_conds, join(' ', @cond));
            
            
        } elsif($cur_block =~ m/^(FEW|SCT|BKN|OVC)(\d{3})(CB|TCU)?$/) { # SKY
            my ($cover, $height, $type) = ($1, $2, $3);
            
            $cover =~ s/FEW/few/;
            $cover =~ s/SCT/scattered/;
            $cover =~ s/BKN/broken/;
            $cover =~ s/OVC/overcast/;
            
            $height *= 100;
            
            my %hash;
            $hash{'cover'} = $cover;
            $hash{'height'} = &make_value_unit($height, 'ft');
            if(defined $type) {
                $hash{'type'} = $type;
            }
            
            push(@cloud_conds, \%hash);
            
            
        } elsif($cur_block =~ m/^RMK$/) {       # BEGIN REMARKS
            last;
        } else {
            push(@unknown_blocks, $cur_block);
        }
    }
    
    while(my $cur_block = shift @metar) { # parse remarks
        if($cur_block =~ m/^T(\d)(\d{3})(?:(\d)(\d{3}))$/) {    # TEMP
            my $temp = $2;
            $temp *= -1 if $1 == 1;
            $weather_data{'temperature'} = &make_value_unit($temp / 10, 'C');
            
            if(defined $4) {
                $temp = $4;
                $temp *= -1 if $3 == 1;
                $weather_data{'dew_point'} = &make_value_unit($temp / 10, 'C');
            }
            
            
        } elsif($cur_block =~ m/^P(\d{4})$/) {                  # PRECIP
            $weather_data{'precip_in_last_hr'} = &make_value_unit($1/100, 'in');
            
            
        } else {
            push(@unknown_remarks, $cur_block);
        }
    }
    
    if(%timedate) {
        $weather_data{'report_time'} = \%timedate;
    }
    if(@sky_conds) {
        $weather_data{'sky_conditions'} = \@sky_conds;
    }
    if(@cloud_conds) {
        $weather_data{'cloud_conditions'} = \@cloud_conds;
    }
    if(@unknown_remarks) {
        $weather_data{'unknown_remarks'} = \@unknown_remarks;
    }    
    if(@unknown_blocks) {
        $weather_data{'unknown_blocks'} = \@unknown_blocks;
    }
    return \%weather_data;
}

sub make_value_unit {
    my ($value, $unit) = @_;
    return { 'value' => $value, 'unit' => $unit };
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
        return &round($temp_c)
            . ($flags & NO_UNITS ? '' : '°C');
    }
    
    if($flags & UNITS_IMPERIAL) {
        return &round($temp_f)
            . ($flags & NO_UNITS ? '' : '°F');
    }
    
    return &round($temp_f) . ($flags & NO_UNITS ? '' : '°F')
    . ' (' . &round($temp_c) . ($flags & NO_UNITS ? '' : '°C') . ')';
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
        return &round($speed) . ($flags & NO_UNITS ? '' : ' ' . $unit);
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
        return &round($speed_kmh) . ($flags & NO_UNITS ? '' : ' km/h');
    }
    
    if($flags & UNITS_IMPERIAL) {
        return &round($speed_mph) . ($flags & NO_UNITS ? '' : ' MPH');
    }
    return &round($speed_mph) . ($flags & NO_UNITS ? '' : ' MPH'). ' (' . &round($speed_kmh) . ($flags & NO_UNITS ? '' : ' km/h') . ')';
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
        return &round($dist) . ($flags & NO_UNITS ? '' : ' ' . $unit);
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
        return &round($dist_km)
            . ($flags & NO_UNITS ? '' : ' km');
    }
    
    if($flags & UNITS_IMPERIAL) {
        return &round($dist_mi)
            . ($flags & NO_UNITS ? '' : ' mi');
    }
    
    return &round($dist_mi) . ($flags & NO_UNITS ? '' : ' mi')
    . ' (' . &round($dist_km) . ($flags & NO_UNITS ? '' : ' km') . ')';
}

sub deg_to_compass {
    my $deg = $_[0];
    
    if($deg < 0 || $deg > 365) {
        my @caller = caller(1);
        warn "absurd angle given to deg_to_compass, called from $caller[3] line $caller[2]";
        return $deg;
    }
    if($deg < 11.25) {
        return 'North';
    } elsif($deg < 33.75) {
        return 'NNE';
    } elsif($deg < 56.25) {
        return 'Northeast';
    } elsif($deg < 78.75) {
        return 'ENE';
    } elsif($deg < 101.25) {
        return 'East';
    } elsif($deg < 123.75) {
        return 'ESE';
    } elsif($deg < 146.25) {
        return 'Southeast';
    } elsif($deg < 168.75) {
        return 'SSE';
    } elsif($deg < 191.25) {
        return 'South';
    } elsif($deg < 213.75) {
        return 'SSW';
    } elsif($deg < 236.25) {
        return 'Southwest';
    } elsif($deg < 258.75) {
        return 'WSW';
    } elsif($deg < 281.25) {
        return 'West';
    } elsif($deg < 303.75) {
        return 'WNW';
    } elsif($deg < 326.25) {
        return 'Northwest';
    } elsif($deg < 348.75) {
        return 'NNW';
    } else {
        return 'North';
    }
}

sub round {
    return int($_[0] + .5 * ($_[0] <=> 0));
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

