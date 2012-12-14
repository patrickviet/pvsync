#!/usr/bin/perl

#-------------------------------------------------------------------------------
# pvsync_client.pl
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
use POE qw(Component::Client::TCP Wheel::Run Filter::Stream);
use File::Path;
use Config::Tiny;
use Getopt::Long;


system("rm /dev/shm/pvsync_tok_*");
my $configfile = "/etc/pvsync_client.conf";
GetOptions( "f=s", => \$configfile );

my $conf = Config::Tiny->read($configfile)
  or die "unable to read config $configfile: $!";

my $position_file = $conf->{_main}->{runfile};
#my $posconf = Config::Tiny->read($position_file);
my $posconf = {};
#$posconf or $posconf = Config::Tiny->new();

# REAP CRAP
$SIG{CHLD} = "IGNORE";

foreach my $module ( keys %$conf ) {
  next if $module =~ m/^_/;
  my ($server,$port,$username,$password,$localdir) = 
  @{$conf->{$module}}{'server','port','username','password','localdir'};

  POE::Component::Client::TCP->new(
    RemoteAddress => $server,
    RemotePort    => $port,
    Connected     => sub { $_[KERNEL]->yield( 'connected', $module ); },
    ConnectError  => sub { print "connect error\n"; $_[KERNEL]->delay_set('reconnect',5); },
    Disconnected  => \&disconnected,
    ServerInput   => \&welcome,

    InlineStates  => {
        'connected' => \&connected,
        'keepalive' => \&keepalive,
        'get_message'      => \&get_message,
        'process_messages' => \&process_messages,
        'rsync_start'   => \&rsync_start,
        'rsync_end'     => \&rsync_end,
        'rsync_out'     => sub { $_[HEAP]->{rsync_stamp} = time(); print "rsync out : ".$_[ARG0]."\n"; },
	'disconnected'  => \&disconnected,
	'rsync_check_timeout' => \&rsync_check_timeout,
    }
  );

}


$poe_kernel->run();


sub rsync_check_timeout {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  print "rsync timeout step 1\n";
  if ($heap->{rsync}) {
    print "rsync timeout step 2\n";
    if ($heap->{rsync_stamp} + 60 < scalar time()) {
      print "rsync timeout 3\n";
      $heap->{rsync}->event( CloseEvent => 'rsync_end_error' );
      $heap->{rsync}->kill(9);
      my $cmd = "ps auxwwww|grep rsync|grep ".$heap->{token}."|awk '{print \$2}'|xargs kill -9";
      print "cmd: $cmd\n";
      system($cmd);
      $heap->{rsync} = undef;
      unlink $heap->{token};

      # lets resync :(
      $kernel->yield('shutdown');
    }
  }
  $kernel->delay_set('rsync_check_timeout',10);
}

sub disconnected {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  if ($heap->{rsync}) {
    # rsync running : lets wait
    print "rsync running: lets wait before reconnect\n";
    $kernel->delay_set('disconnected',5);
  } else {
    # lets go !
    print "disconnected!\n";
    $kernel->delay_set('reconnect',5);
  }
}


sub rsync_start {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  return if defined $heap->{rsync};
  return unless scalar scalar @{$heap->{rsync_queue}};

  # make token
  my $token = '/dev/shm';
  my $module = $heap->{module};
  while(-e $token) { $token = '/dev/shm/pvsync_tok_'.$$.'_'.time().'.'.scalar rand(10); }
  open TOK, ">$token" or die $!;
  print TOK join("\n",@{$heap->{rsync_queue}});
  close TOK;

  print "starting rsync for ".scalar @{$heap->{rsync_queue}}." files\n";
 
  my $extra = "";
  if ($heap->{rsync_queue}->[0] eq '.') {
    print "full resync for $module\n";
  } else {
    $extra = "--files-from=$token ";
  }
  
  $heap->{rsync_stamp} = time();
  $heap->{rsync} = POE::Wheel::Run->new(
    Program    => "/usr/bin/env RSYNC_PASSWORD=".$conf->{$module}->{password}." /usr/bin/rsync -av --progress --delete $extra".
                  "rsync://".$conf->{$module}->{username}.'@'.$conf->{$module}->{server}."/$module/ ".$conf->{$module}->{localdir}.'/',
    StdoutEvent => 'rsync_out',
    StderrEvent => 'rsync_out',
    CloseEvent => 'rsync_end',
    StdoutFilter => POE::Filter::Stream->new(),
    StderrFilter => POE::Filter::Stream->new(),

  );

  $heap->{attrib_position_shift} += scalar @{$heap->{rsync_queue}};
  $heap->{rsync_queue} = [];
  $heap->{token} = $token
  
}

sub rsync_end {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  print "rsync end\n";
  $heap->{rsync} = undef;
  unlink $heap->{token};

  $heap->{exec_position} += $heap->{attrib_position_shift};
  $heap->{attrib_position_shift} = 0;

  $kernel->yield('process_messages');
  $kernel->yield('rsync_start');

  my $module = $heap->{module};
  $posconf->{$module}->{position} = $heap->{exec_position};
  #$posconf->write( $position_file );

}

sub welcome {
  my ($kernel,$message,$heap) = @_[KERNEL,ARG0,HEAP];
  print "message: $message\n";
  if ($message eq 'welcome') {
    $heap->{server}->event( InputEvent => 'get_message' );
  } else {
    # ERREUR
    if ($message =~ m/position unexistant\. current is ([0-9]+)/) {
      $heap->{rsync_queue} = [ '.' ];
      $kernel->yield('rsync_start');
      $heap->{exec_position} = $1;
      $heap->{attrib_position_shift} = -1; # to ignore the resynchronization of ./
      
    }
  } 
}

sub connected {
  my ($kernel,$heap) = @_[KERNEL,HEAP];

  unless (defined ($heap->{done_init})) {
    do_init(@_);
  }

  my $module = $heap->{module};

  return unless ref($heap->{server}) eq 'POE::Wheel::ReadWrite';
  
  print "connected. requesting $module / ".$heap->{exec_position}."\n";

  $heap->{server}->put( join(' ',
    $conf->{$module}->{username},
    $conf->{$module}->{password},
    $module,
    $heap->{exec_position}
  ));

  $heap->{rsync} = undef;

  $kernel->delay_set('rsync_check_timeout',10);
}

sub do_init {
  my ($kernel,$heap,$module) = @_[KERNEL,HEAP,ARG0];
  $kernel->delay_set('keepalive',5);

  my $position = 0;
  #if (exists $posconf->{$module}->{position}) {
  #  $position = $posconf->{$module}->{position} if $posconf->{$module}->{position};
  #}

  $posconf->{$module}->{position} = $position;
  
  $heap->{module} = $module;
  $heap->{rsync} = undef;
  $heap->{rsync_queue} = [];
  $heap->{exec_position} = $position;
  $heap->{message_queue} = [];
  $heap->{attrib_position_shift} = 0;

  $heap->{done_init} = 1;
}

sub get_message {
  my ($kernel,$heap,$message) = @_[KERNEL,HEAP,ARG0];
  print "get message: $message\n";

  push @{$heap->{message_queue}}, $message;
  $kernel->yield('process_messages');
}

sub process_messages {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  return unless @{$heap->{message_queue}};
  
  if ($heap->{rsync}) {
    # attrib can get easily queued : rsync will put the right thing anyway
    # tar xzvf sets attrib at each write so it's cool to queue ...
    unless ( $heap->{message_queue}->[0] =~ m/^(write|create_dir|attrib)/ ) {
       print "rejected execution for ".$heap->{message_queue}->[0]."\n";
       return;
    }
  }

  
  my $message = shift @{$heap->{message_queue}};
  print "process message: $message\n";  
  my ($action,$file,$param2,$stamp) = split(/\ /, $message);

  return if $file =~ m/\.\./;
  print "exec message: $message\n";

  my $module = $heap->{module};
  my $localdir = $conf->{$module}->{localdir};

  if ($action eq 'attrib') {
    my ($mode,$uid,$gid) = split(/\|/, $param2);
    chmod oct($mode),$localdir.'/'.$file;
    print "chmod $param2 on $file\n";
    chown $uid,$gid,$localdir.'/'.$file;
    print "chown $uid:$gid on $file\n";
    if ($heap->{rsync}) {
      $heap->{attrib_position_shift}++;
    } else {
      $heap->{exec_position}++;
    }
  } 
  elsif ($action eq 'write' or $action eq 'create_dir') {
    push @{$heap->{rsync_queue}},$file;
    $kernel->yield('rsync_start') unless defined $heap->{rsync};
  }
  elsif ($action eq 'delete_file') {
    unlink $localdir.'/'.$file;
    $heap->{exec_position}++;
  }
  elsif ($action eq 'delete_dir') {
    # rmtree can catch any desync crap
    rmtree $localdir.'/'.$file;
    $heap->{exec_position}++;
  }
  elsif ($action eq 'move_dir' or $action eq 'move_file') {
    # systematic rsync after rename is cool
    #if (-e $param2) {
      rename $localdir.'/'.$param2, $localdir.'/'.$file;
    #  $heap->{exec_position}++;
    #} else {
      # if it has already been moved/deleted/other : get its destination directly!
      push @{$heap->{rsync_queue}},$file;
      $kernel->yield('rsync_start') unless defined $heap->{rsync};
    #}
  }
  elsif ($action eq 'rmtree') {
    rmtree $localdir.'/'.$file;
    $heap->{exec_position}++;
  }
  else {
   # should not be here
   print "beuargh\n";
  }

  
  $kernel->yield('process_messages') if scalar @{$heap->{message_queue}};
  $kernel->yield('rsync_start') if scalar @{$heap->{rsync_queue}};
}

sub keepalive {
  my ($kernel,$heap) = @_[KERNEL,HEAP];

  my $wheel = $heap->{server};
  if (defined($wheel)) {
    $wheel->put('keepalive');
  } 

  my $module = $heap->{module};
  $posconf->{$module}->{position} = $heap->{exec_position};

  #$posconf->write( $position_file ) if defined $heap->{server};  
  $kernel->delay_set('keepalive',5);
}
