# SimBot Weather Plugin
#
# Copyright (C) 2003, Pete Pearson
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

package SimBot::plugin::weather;

# GET_WX: Fetches a METAR report and gives a few weather conditions
sub get_wx {
    my ($kernel, $nick, $channel, $command, $station) = @_;
    if(length($station) != 4) {
	# Whine and bail
	$kernel->post(bot => privmsg => $channel,
               "$nick: " . ($station ? "That doesn't look like a METAR station. " : 'Please provide a METAR station ID. ') . 'You can look up station IDs at <http://www.nws.noaa.gov/tg/siteloc.shtml>.');
	return;
    }
    $station = uc($station);
    my $url = 'http://weather.noaa.gov/pub/data/observations/metar/stations/'
        . $station . '.TXT';
    SimBot::debug(3, 'Received weather command from ' . $nick .
	   " for $station\n");
    my $useragent = LWP::UserAgent->new(requests_redirectable => undef);
    $useragent->agent("$SimBot::project/1.0");
    $useragent->timeout(5);
    my $request = HTTP::Request->new(GET => $url);
    my $response = $useragent->request($request);
    if (!$response->is_error) {
	my (undef, $raw_metar) = split(/\n/, $response->content);

	# We can translate ID to Name! :)
    unless($stationNames{$station}) {
        SimBot::debug(3, "Station name not found, looking it up\n");
    	my $url = 'http://weather.noaa.gov/cgi-bin/nsd_lookup.pl?station='
    	    . $station;
    	my $useragent = LWP::UserAgent->new(requests_redirectable => undef);
    	$useragent->agent("$SimBot::project/1.0");
    	$useragent->timeout(5);          
    	my $request = HTTP::Request->new(GET => $url);
    	my $response = $useragent->request($request);
#    	my $station_name = $station;     
    	if (!$response->is_error && $response->content !~ /The supplied value is invalid/ && $response->content !~ /No station matched the supplied identifier/) {
    	    $response->content =~ m|Station Name:.*?<B>(.*?)\s*</B>|s;
    	    my $name = $1;               
    	    $response->content =~ m|State:.*?<B>(.*?)\s*</B>|s;
    	    my $state = ($1 eq $name ? undef : $1);
    	    $response->content =~ m|Country:.*?<B>(.*?)\s*</B>|s;
    	    my $country = $1;            
    	    $stationNames{$station} = "$name, " . ($state ? "$state, " : "")
    		. "$country ($station)";
    	}
    }

	# If the user asked for a metar, we'll give it to them now!
	if ($command =~ /^.metar$/) {
	    $kernel->post(bot => privmsg => $channel, "$nick: METAR report for " . (defined $stationNames{$station} ? $stationNames{$station} : $station) .  " is $raw_metar.");
	    return;
	}

        # Geo::METAR has issues not ignoring the remarks section of the
        # METAR report. Let's strip it out.
        SimBot::debug(3, "METAR is " . $raw_metar . "\n");
        $raw_metar =~ s/^(.*?) RMK .*$/$1/;
        $raw_metar =~ s|/////KT|00000KT|;
        SimBot::debug(3, "Reduced METAR is " . $raw_metar . "\n");

	my $m = new Geo::METAR;
	$m->metar($raw_metar);

	# Let's form a response!
        $m->{date_time} =~ m/\d\d(\d\d)(\d\d)Z/;
        my $time = "$1:$2";
	my $reply = "As reported at $time GMT at " .
	   (defined $stationNames{$station} ? $stationNames{$station}
	                                    : $station);
	my @reply_with;

	# There's no point in this exercise unless there's data in there
	if ($raw_metar =~ /NIL$/) {
	    $reply .= " there is no data available";
	} else {
	    # Temperature and related details *only* if we have a temperature!
	    if (defined $m->TEMP_C || $raw_metar =~ m|(M?\d\d)/|) {
		# We have a temp, "it is"
		$reply .= " it is ";

		# This nonsense checks to see if we have a temperature in the
		# report that Geo::METAR is too stupid to see.
		my $temp_c = (defined $m->TEMP_C ? $m->TEMP_C : $1);
		$temp_c =~ s/M/-/;
		my $temp_f = (defined $m->TEMP_F ? $m->TEMP_F : (9/5)*$temp_c+32);

		my $temp = $temp_f . '°F (' . int($temp_c) . '°C)';
		push(@reply_with, $temp);

		if($temp_f <= 40 && $m->WIND_MPH > 5) {
		    my $windchill = 35.74 + (0.6215 * $temp_f)
			- 35.75 * ($m->WIND_MPH ** 0.16)
			+ 0.4275 * $temp_f * ($m->WIND_MPH ** 0.16);
		    my $windchill_c = ($windchill - 32) * (5/9);
		    push(@reply_with, sprintf('a wind chill of %.1f°F (%.1f°C)', $windchill, $windchill_c));
		}

		# Humidity, only if we have a dewpoint!
		if (defined $m->C_DEW) {
		    my $humidity = 100 * ( ( (112 - (0.1 * $temp_c) + $m->C_DEW)
					     / (112 + (0.9 * $temp_c)) ) ** 8 );
		    push(@reply_with, sprintf('%d', $humidity) . '% humidity');
		}
	    } else {
		# We have no temp, "there are" (winds|skies)
		$reply .= " there are ";
	    }

	    if($m->WIND_MPH) {
		my $tmp = int($m->WIND_MPH) . ' mph';
		if ($m->WIND_DIR_ENG) {
		    $tmp .= ' winds from the ' . $m->WIND_DIR_ENG;
		} else {
		    $tmp .= ' variable winds';
		}
		push(@reply_with, $tmp);
	    }

	    push(@reply_with, @{$m->WEATHER});
	    my @sky = @{$m->SKY};
# Geo::METAR returns sky conditions that can't be plugged into sentences nicely
# let's clean them up.
	    for(my $x=0;$x<=$#sky;$x++) {
		$sky[$x] = lc($sky[$x]);
		$sky[$x] =~ s/solid overcast/overcast/;
		$sky[$x] =~ s/sky clear/clear skies/;

		$sky[$x] =~ s/(broken|few|scattered) at/$1 clouds at/;
	    }

	    push(@reply_with, @sky);

	    $reply .= shift(@reply_with);
	    $reply .= " with " . join(', ', @reply_with) if @reply_with;
	}
        $reply .= '.';

	$kernel->post(bot => privmsg => $channel, "$nick: $reply");
    } else {
	if ($response->code eq "404") {
	    $kernel->post(bot => privmsg => $channel, "$nick: Sorry, there is no METAR report available matching \"$station\". You can look up station IDs at <http://www.nws.noaa.gov/tg/siteloc.shtml>.");
	} else {
	    $kernel->post(bot => privmsg => $channel, "$nick: Sorry, I could not access NOAA.");
	}
    }
}

sub cleanup_wx {
    SimBot::debug(3, "Saving station names\n");
    dbmclose(%stationNames);
}

sub messup_wx {
    SimBot::debug(3, "Loading station names...\n");
    dbmopen (%stationNames, 'metarStationNames', 0664) || return 0;
}

package SimBot::plugin::metar;

# GET_METAR: Asks the weather plugin to return the raw METAR report
sub get_metar {
    SimBot::plugin::weather::get_wx(@_);
}

# Register Plugins
SimBot::plugin_register(plugin_id   => "weather",
			plugin_desc => "Gets a weather report for the given station.",
			modules     => "Geo::METAR,LWP::UserAgent",

			event_plugin_call    => "get_wx",
            event_plugin_load    => "messup_wx",
			event_plugin_unload  => "cleanup_wx",
			);

SimBot::plugin_register(plugin_id   => "metar",
			plugin_desc => "Gives a raw METAR report for the given station.",
			modules     => "LWP::UserAgent",

			event_plugin_call => "get_metar",
			);
