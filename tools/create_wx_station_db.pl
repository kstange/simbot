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
use File::Listing;

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
$ua->default_header('Accept-Encoding' => 'gzip, deflate');


# Now with the boring stuff down, get the rather large METAR list
print "Downloading METAR station list... ";
my $response = $ua->get('http://weather.noaa.gov/data/nsd_cccc.gz');

if($response->is_error) {
    print STDERR "Failed!\n  " . $response->code . ' '
    . $response->message . "\n";
    $dbh->rollback;
    exit(1);
} else {
    print "Done!\nReading it in";
    my $content = $response->decoded_content;
    my $cur_line;
    my $line_count = 0;
    
    my $update_station_query = $dbh->prepare(
    'INSERT OR REPLACE INTO stations (id, name, state, country, latitude, longitude)'
    . ' VALUES (?,?,?,?,?,?)');
    
    while($content) {
        if(++$line_count % 300 == 0) { print '.'; }
        ($cur_line, $content) = split(/\n/, $content, 2);
        my ($station, undef, undef, $name, $state, $country, undef, $lat_dms, $long_dms, undef, undef, $rbsn) = split(/;/, $cur_line);
        
        $name =~ s/\s+$//;
        $name =~ s/^\s+//;
        
        my ($long_deg);
        my ($lat_deg, $minutes, $seconds, $dir) = $lat_dms
            =~ m/(\d+)-(\d+)(?:-(\d+))?([NS])/;
        $lat_deg = &dms_to_degrees($lat_deg, $minutes, $seconds, $dir);
        
        ($long_deg, $minutes, $seconds, $dir) = $long_dms
            =~ m/(\d+)-(\d+)(?:-(\d+))?([EW])/;
        $long_deg = &dms_to_degrees($long_deg, $minutes, $seconds, $dir);
        
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
    print " Done! Read $line_count lines\n"
}

# OK, now we have a great list of station codes. However, not all have
# METAR reports. Let's find codes to remove...

print "Downloading METAR directory listing (this may take a while)... ";
$response = $ua->get('ftp://weather.noaa.gov/data/observations/metar/stations/');

if($response->is_error) {
    print STDERR "Failed! " . $response->code . ' ' . $response->message . "\n";
    $dbh->rollback;
    exit(1);
} else {
    my $line_count = 0;
    print "Done!\nReading it in";
    
    # Create a temporary table as a list of candidates for deletion
    $dbh->do(<<EOT);
CREATE TEMPORARY TABLE delrows AS SELECT id FROM stations;
CREATE UNIQUE INDEX delstationid ON delrows (id);
EOT

    my $remove_from_deletion_list_query = $dbh->prepare(
        'DELETE FROM delrows WHERE id = ?');
        
    my @listing = parse_dir($response->content);
    
    foreach my $cur_file (@listing) {
        if(++$line_count % 300 == 0) { print '.'; }
        my ($name) = @$cur_file;
        
        if($name =~ /^([A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9])/) {
            $remove_from_deletion_list_query->execute($1);
        }
    }
    print " Done! Read $line_count lines.\n";
    
    my $useless_fact_query = $dbh->prepare('SELECT count() FROM delrows');
    $useless_fact_query->execute;
    my ($deletion_count) = $useless_fact_query->fetchrow_array;
    print "Removing $deletion_count stations without reports... ";
    
    $dbh->do(
        'DELETE FROM stations WHERE id IN (SELECT id FROM delrows)');
    print "Done!\n";
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
