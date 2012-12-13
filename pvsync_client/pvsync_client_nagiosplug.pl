#!/usr/bin/perl

#-------------------------------------------------------------------------------
# pvsync_client_nagiosplug.pl
# Patrick Viet 2008-2012 - patrick.viet@gmail.com
# GITHUB PUBLIC REPO: http://github.com/patrickviet/pvsync
#
# Licence: BSD
# Basically I guarantee nothing, and you can do what you want with it, as long 
# as you give me credit, keep this notice, don't say you made it or use my 
# name/the name of the product to endorse something you made.
#
#-------------------------------------------------------------------------------

use warnings;
use strict;
use Config::Tiny;

my $conf = Config::Tiny->read('/etc/pvsync_client.conf');

my $decalage = shift @ARGV;
$decalage or $decalage = 180;
die "decalage syntax" if $decalage =~ m/[^0-9]/;

foreach my $module (keys %$conf) {
  next if $module =~ m/^_/;
  my $path = $conf->{$module}->{localdir};

  opendir(my $dh,$path) or die $!;

  my @stamps = ();
  while(my $file = readdir($dh)) {
    next unless $file =~ m/^monitor_pvsync_server_$module\_([0-9]+)$/;
    push @stamps, $1;
  }
  closedir($dh);

  unless (scalar @stamps) { print "CRITICAL pvsync_CLIENT - no file for $module\n"; exit 2; }
  @stamps = sort @stamps;
  my $last_stamp = pop @stamps;
  my $now = time();
  if (($last_stamp + $decalage) < $now) { print "CRITICAL pvsync_CLIENT - sync too old (".localtime($last_stamp).")\n"; exit 2; }
}

print "OK pvsync_CLIENT - all on time\n"; exit 0;

