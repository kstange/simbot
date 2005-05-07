#!/usr/bin/perl

# SimBot Weather Station Names Importer
#
# DESCRIPTION:
#   Imports the list of METAR stations from NOAA's web site.
#
# USAGE: 
#   While inside SimBot's directory, run tools/create_wx_station_db.pl
#
# COPYRIGHT:
#   Copyright (C) 2005, Pete Pearson
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

use Compress::Zlib;
use LWP::UserAgent;
use DBI;
use XML::Simple;

use warnings;
use strict;

# turn off IO buffering on STDOUT
$| = 1;

# let's create our database
my $dbh = DBI->connect('dbi:SQLite:dbname=data/weather','','',
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
EOT

}
# we'll create the indices when we are done, it's supposedly faster

# Set up our user agent
my $ua = LWP::UserAgent->new;
if (defined &HTTP::Response::decoded_content) {
	$ua->default_header('Accept-Encoding' => 'gzip, deflate');
} else {
	print "Warning: Your HTTP::Response does not support gzip\n";
}

# Now with the boring stuff down, get the rather large METAR list
print "Downloading METAR station list... ";
my $response = $ua->get('http://weather.noaa.gov/data/nsd_cccc.gz');

if($response->is_error) {
    print STDERR "Failed!\n  " . $response->code . ' '
    . $response->message . "\n";
} else {
    print "Done!\nReading it in";
	my $content;
	if (defined &HTTP::Response::decoded_content) {
		$content = $response->decoded_content;
	} else {
		$content = $response->content;
	}
    my $cur_line;
    my $line_count = 0;
    
    my $update_station_query = $dbh->prepare(
    'INSERT OR REPLACE INTO stations (id, name, state, country, latitude, longitude)'
    . ' VALUES (?,?,?,?,?,?)');
    
    while($content) {
        if(++$line_count % 300 == 0) { print '.'; }
        ($cur_line, $content) = split(/\n/, $content, 2);
        my ($station, undef, undef, $name, $state, $country, undef, $lat_dms, $long_dms) = split(/;/, $cur_line, 10);
        
		my ($lat_deg, $long_deg, $minutes, $seconds, $dir);
		if (defined $lat_dms) {
			($lat_deg, $minutes, $seconds, $dir) = $lat_dms
				=~ m/(\d+)-(\d+)(?:-(\d+))?([NS])/;
			$lat_deg = &dms_to_degrees($lat_deg, $minutes, $seconds, $dir);
        }
		if (defined $long_dms) {
			($long_deg, $minutes, $seconds, $dir) = $long_dms
				=~ m/(\d+)-(\d+)(?:-(\d+))?([EW])/;
			$long_deg = &dms_to_degrees($long_deg, $minutes, $seconds, $dir);
        }
        {
            no warnings qw( uninitialized );
            $update_station_query->execute(
                $station,
                $name,
                ($state ? $state : undef),
                $country,
                $lat_deg,
                $long_deg,
            );
        }
    }
    print "\nDone! Read $line_count lines\n"
}

# now let's get the XML data file.
# this only has US stations, and generally lacks lat/long.

print "Downloading XML station list... ";
$response = $ua->get('http://www.nws.noaa.gov/data/current_obs/index.xml');

if($response->is_error) {
    print STDERR "Failed!\n  " . $response->code . ' '
    . $response->message . "\n";
} else {
    print "Done!\nReading it in";
    my $xml;
	my $content;
 	if (defined &HTTP::Response::decoded_content) {
		$content = $response->decoded_content;
	} else {
		$content = $response->content;
	}
   if (!eval { $xml = XMLin($content, SuppressEmpty => 1); }) {
		print STDERR " Failed!\n$@\n";
    } else {
        my $update_station_query = $dbh->prepare(
            'UPDATE stations SET url = ? WHERE id = ?');
        my $line_count = 0;
        foreach my $cur_station (@{$xml->{'station'}}) {
            if(++$line_count % 300 == 0) { print '.'; }
            no warnings qw( uninitialized );
                        
            $update_station_query->execute(
                $cur_station->{'xml_url'},
                $cur_station->{'station_id'}
            );
        }
        print "\nDone! Read $line_count lines\n";
    }
}

{
    local $dbh->{RaiseError}; # let's not die on errors
    local $dbh->{PrintError}; # and let's be quiet
    $dbh->do(<<EOT);
CREATE UNIQUE INDEX stationid
    ON stations (id);

CREATE INDEX latlong
    ON stations (latitude, longitude);
EOT

}

$dbh->commit;
$dbh->disconnect;

sub dms_to_degrees {
    my ($degrees, $minutes, $seconds, $dir) = @_;
    
    if(defined $minutes)    { $degrees += $minutes * 0.0166666667; }
    if(defined $seconds)    { $degrees += $seconds * 0.000277777778; }
    
    if(defined $dir && $dir =~ m/[SW]/) { $degrees = $degrees * -1; }
    
    return $degrees;
}
