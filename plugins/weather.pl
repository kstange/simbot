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
    my ($kernel, $nick, $channel, undef, $station) = @_;
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
    $useragent->agent("$project/1.0");
    $useragent->timeout(5);
    my $request = HTTP::Request->new(GET => $url);
    my $response = $useragent->request($request);
    if (!$response->is_error) {
	my (undef, $raw_metar) = split(/\n/, $response->content);
	my $m = new Geo::METAR;

        # Geo::METAR has issues not ignoring the remarks section of the
        # METAR report. Let's strip it out.
        $raw_metar =~ s/^(.*?) RMK .*$/$1/;
        SimBot::debug(3, "METAR is " . $raw_metar . "\n");
	$m->metar($raw_metar);

	# Let's form a response!
        $m->{date_time} =~ m/\d\d(\d\d)(\d\d)Z/;
        my $time = "$1:$2";
	my $reply = "As reported at $time UTC at $station it is ";
	my @reply_with;
	$reply .= $m->TEMP_F . '°F (' . int($m->TEMP_C) . '°C) ' if defined $m->TEMP_F;

        if($m->TEMP_F <= 40 && $m->WIND_MPH > 5) {
            my $windchill = 35.74 + (0.6215 * $m->TEMP_F)
                - 35.75 * ($m->WIND_MPH ** 0.16)
                + 0.4275 * $m->TEMP_F * ($m->WIND_MPH ** 0.16);
            my $windchill_c = ($windchill - 32) * (5/9);
            push(@reply_with, sprintf('a wind chill of %.1f°F (%.1f°C)', $windchill, $windchill_c));
        }

        my $humidity = 100 * ( ( (112 - (0.1 * $m->TEMP_C) + $m->C_DEW) /
                                 (112 + (0.9 * $m->TEMP_C)) ) ** 8 );
        push(@reply_with, sprintf('%d', $humidity) . '% humidity');

	if($m->WIND_MPH) {
	    my $tmp = int($m->WIND_MPH) . ' mph winds';
            $tmp .= ' from the ' . $m->WIND_DIR_ENG if defined $m->WIND_DIR_ENG;
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

        $reply .= "with " . join(', ', @reply_with) if @reply_with;
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

# Register Plugin
SimBot::plugin_register(plugin_id   => "weather",
			plugin_desc => "Gets a weather report for the given station.",
			modules     => "Geo::METAR,LWP::UserAgent",

			event_plugin_call => "get_wx",
			);
