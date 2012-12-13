#!/usr/bin/perl

#-------------------------------------------------------------------------------
# pvsync_server_monitor.pl
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

my $conf = Config::Tiny->read('/etc/pvsync_server.conf');

foreach my $module (keys %$conf) {
  next if $module =~ m/^_/;
  my $path = $conf->{$module}->{path};

  opendir(my $dh,$path) or die $!;
 
  my @files = ();
  while(my $file = readdir($dh)) {
    next unless $file =~ m/monitor_pvsync_server_$module/;
    push @files,$file; 
  }

  closedir($dh);

  my $writefile;
  do {
    $writefile = "$path/monitor_pvsync_server_$module"."_".time();
  } while (-f $writefile);

  open my $fh, "> $writefile" or die $!;
  close $fh;
  foreach (@files) { unlink "$path/$_"; }
}
