#!/usr/bin/perl

#-------------------------------------------------------------------------------
# pvsync_server.pl
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
use POE qw(Component::Server::TCP);
use Linux::Inotify2;
use Config::Tiny;
use Getopt::Long;
use Data::Dumper;

#-------------------------------------------------------------------------------
# Declare variables

my $auth          = {};
my $modules       = {};
my $module_queues = {};
my $move_queue    = {};
my $clients       = {};
my $clients_wait  = {};
my $move_source   = "";
my $move_cookie   = "";

#-------------------------------------------------------------------------------
# proc
open INOTIFYPROC, "/proc/sys/fs/inotify/max_user_watches" or die $!;
my $inotify_proc = <INOTIFYPROC>;
close INOTIFYPROC;
chomp $inotify_proc;
if ($inotify_proc < 1048576) {
  open INOTIFYPROC, ">/proc/sys/fs/inotify/max_user_watches" or die $!;
  print INOTIFYPROC "1048576";
  close INOTIFYPROC;
}

#-------------------------------------------------------------------------------
# Read config

$0 = "pvsync_server.pl: read conf";

my $configfile = "/etc/pvsync_server.conf";
GetOptions( "f=s", => \$configfile );

my $conf = Config::Tiny->read($configfile)
  or die "unable to read config $configfile: $!";

# Logs
my $log_max_size = $conf->{_main}->{log_max_size};

#-------------------------------------------------------------------------------
my $inotify = new Linux::Inotify2
  or die "unable to create inotify: $!";

open my $ifh, "<&=", $inotify->fileno
  or die "could not open fd: $!";

foreach my $username ( keys %{ $conf->{_users} } ) {
    my @modules = split( /\ /, $conf->{_users}->{$username} );
    $auth->{$username}->{password} = shift @modules or die "not enough params";
    $auth->{$username}->{ip}       = shift @modules or die "not enough params";
    scalar @modules or die "not enough params";
    $auth->{$username}->{modules} = \@modules;
}


foreach my $module ( keys %$conf ) {
    next if $module =~ m/^\_/;
    $modules->{$module} = {
        path       => $conf->{$module}->{path},
        log_start  => 1,
        log_curpos => 1,
        # start at 1 so that client starting at 0 auto resyncs
    };
}

my $rsync_conf = {};
foreach my $module ( keys %$modules ) {
    $rsync_conf->{$module}->{path}          = $modules->{$module}->{path};
    $rsync_conf->{$module}->{uid}           = 0;
    $rsync_conf->{$module}->{'auth users'}  = "";
    $rsync_conf->{$module}->{'hosts allow'} = "";
    if ($conf->{$module}->{exclude}) {
      $rsync_conf->{$module}->{'exclude'} = $conf->{$module}->{exclude};
    }
    open my $secfh, "> /etc/rsyncd.secrets.$module";
    $rsync_conf->{$module}->{fh} = $secfh;
}

foreach my $username ( keys %$auth ) {
    foreach my $module ( @{ $auth->{$username}->{modules} } ) {
        die "unexistant module: $username/$module" unless exists $modules->{$module};
        my $secretfile = "/etc/rsyncd.secrets." . $module;
        $rsync_conf->{$module}->{'auth users'} .= ' ' . $username;
        $rsync_conf->{$module}->{'hosts allow'} .=
          ' ' . $auth->{$username}->{ip};
        $rsync_conf->{$module}->{'secrets file'} = $secretfile;

        my $fh = $rsync_conf->{$module}->{fh};
        print $fh $username . ':' . $auth->{$username}->{password} . "\n";
    }
}

foreach my $module ( keys %$modules ) {
    my $fh = delete $rsync_conf->{$module}->{fh};
    close $fh;
    chmod 0600, "/etc/rsyncd.secrets.$module";
}

open FH, ">/etc/rsyncd.conf" or die $!;

foreach my $module ( keys %$rsync_conf ) {
    print FH "\[$module\]\n";

    foreach my $line ( keys %{ $rsync_conf->{$module} } ) {
        my $param = $rsync_conf->{$module}->{$line};
        while ( $param =~ m/  / ) { $param =~ s/  / /; }
        $param =~ s/^ //g;
        $param =~ s/ $//g;
        print FH '  ' . $line . ' = ' . $param . "\n";
    }

    print FH "\n";
}

if (-f "/etc/rsyncd.conf.include") {
  open FH2, "</etc/rsyncd.conf.include";
  while(<FH2>) { print FH $_; }
  close FH2;
}

close FH;

system("/usr/bin/killall -9 rsync");
system("/usr/bin/rsync --daemon");

my $keepalive_timeout       = $conf->{_main}->{keepalive_timeout};
my $keepalive_timeout_check = $conf->{_main}->{keepalive_timeout_check};

my $main_session = POE::Session->create(
    inline_states => {
        _start             => \&start,
        ievent             => \&ievent,
        send_notifications => \&send_notifications,
        moved_from_rmtree  => \&moved_from_rmtree,
    }
);

POE::Component::Server::TCP->new(
    Port               => "8000",
    Alias              => "tcpserver",
    ClientInput        => \&client_auth,
    ClientConnected    => \&client_connect,       # Optional.
    ClientDisconnected => \&client_disconnect,    # Optional.

    InlineStates => {
        'keepalive'       => \&keepalive,
        'check_keepalive' => \&check_keepalive
    },
);

sub start {
    my $kernel = $_[KERNEL];
    $kernel->select_read( $ifh, 'ievent' );

    foreach my $module ( keys %$modules ) {
        $0 = "pvsync_server.pl: adding recursive watch for $module";
        add_recursive_watch( $modules->{$module}->{path} );
    }
    $0 = "pvsync_server.pl: running";

    $kernel->delay_set( 'auto_log_flush',
        $conf->{_main}->{log_flush_interval} );
    $kernel->delay_set( 'auto_log_unload', 10 );
}

sub moved_from_rmtree {
    my ( $file, $cookie ) = @_[ ARG0, ARG1 ];
    return unless $file;
    return unless $move_cookie eq $cookie;
    return unless $move_source eq $file;

    $move_cookie = '';
    $move_source = '';
    send_sync( 'rmtree', $file );
}

sub keepalive {
    my ( $heap, $kernel, $text ) = @_[ HEAP, KERNEL, ARG0 ];
    if ( $text eq 'QUIT' ) {

        my $wheel = $heap->{client};
        if ( defined($wheel) ) {
            $heap->{client}->put('bye bye');
        }
        return $kernel->yield('shutdown');
    }

    $heap->{keepalive} = time();
}


sub check_keepalive {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

    if ( $heap->{keepalive} + $keepalive_timeout < time() ) {
        my $wheel = $heap->{client};
        if ( defined($wheel) ) {
            $wheel->put('sorry timeout');
        }

        return $kernel->yield('shutdown');
    }

    $kernel->delay_set( 'check_keepalive', $keepalive_timeout_check );
}

sub client_auth {
    my ( $kernel, $text, $heap ) = @_[ KERNEL, ARG0, HEAP ];
    print "got auth: $text\n";

    $heap->{keepalive} = time();

    my @sp = split( /\ /, $text );
    unless ( scalar @sp == 4 ) {
        $heap->{client}->put('param error');
        return $kernel->yield('shutdown');
    }

    my ( $user, $pass, $module, $position ) = @sp;

    unless ( exists $auth->{$user} ) {
        $heap->{client}->put('userpass error');
        return $kernel->yield('shutdown');
    }

    unless ( $auth->{$user}->{password} eq $pass ) {
        $heap->{client}->put('userpass error');
        return $kernel->yield('shutdown');
    }

    unless ( scalar grep { /^$module$/ } @{ $auth->{$user}->{modules} } ) {
        $heap->{client}->put('module error');
        return $kernel->yield('shutdown');
    }

    if ( $position =~ m/[^0-9]/ ) {
        $heap->{client}->put('position syntax error');
        return $kernel->yield('shutdown');
    }

    my $current_position = $modules->{$module}->{log_curpos};

    if ( $position > $current_position
         or $position < $modules->{$module}->{log_start}) {
        $heap->{client}->put(
            "position unexistant. current is $current_position"
        );
        return $kernel->yield('shutdown');         
    }


    my $wheel = $heap->{client};
    delete $clients_wait->{ $wheel->ID };
    $clients->{ $wheel->ID } =
      [ $wheel, $module, $position, $kernel ];

    $wheel->put('welcome');

    $wheel->event( InputEvent => 'keepalive' );
    $kernel->post( $main_session, 'send_notifications' );
}

sub client_connect {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    my $wheel = $heap->{client};
    print "connected: "
      . $heap->{remote_ip} . ":"
      . $heap->{remote_port} . "\n";
    $clients_wait->{ $wheel->ID } = $wheel;

    $heap->{keepalive} = time();
    $kernel->delay_set( 'check_keepalive', $keepalive_timeout_check );
}

sub client_disconnect {
    my $heap  = $_[HEAP];
    my $wheel = $heap->{client};
    print "disconnected: "
      . $heap->{remote_ip} . ":"
      . $heap->{remote_port} . "\n";
    delete $clients->{ $wheel->ID };
    delete $clients_wait->{ $wheel->ID };
}

sub add_recursive_watch {
    my $dir = shift;
    $inotify->watch( $dir,
        IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_IGNORED | IN_MOVED_TO |
          IN_MOVED_FROM | IN_ATTRIB )
      or die "unable to watch $dir: $!";

    print "watching $dir\n";

    opendir( my $dir_fh, $dir );
    foreach my $file ( readdir($dir_fh) ) {
        next if $file eq '.' or $file eq '..';
        if ( -d "$dir/$file" ) {
            add_recursive_watch("$dir/$file");
        }
    }

    closedir($dir_fh);
}

sub send_notifications {
    my $kernel             = $_[KERNEL];
    my $more_notifications = 0;

    foreach my $cl_id ( keys %$clients ) {
        my ( $wheel, $module, $position ) = @{ $clients->{$cl_id} };

        next unless defined $wheel;

        my $module_queue            = $module_queues->{$module};
        my $log_start_position      = $modules->{$module}->{log_start};
        my $log_current_position = $modules->{$module}->{log_curpos};

        if ( $position < $log_current_position ) {
            # relative position vs. index
            $wheel->put( $module_queue->[$position - $log_start_position] );
            $clients->{$cl_id}->[2]++;
        }

        $more_notifications = 1 if $position < $log_current_position;

    }

    if ($more_notifications) {
        $kernel->post( $main_session, 'send_notifications' );
    }
}

sub ievent {
    my $kernel = $_[KERNEL];
    foreach my $ev ( $inotify->read ) {
        my $file = $ev->fullname;

        # This assumes that a moved_to always follows its moved_from
        if ( $move_source and !( $ev->IN_MOVED_TO ) ) {
            send_sync( 'rmtree', $move_source );
            $move_source = '';
        }

        if ( $ev->IN_CREATE ) {
            if ( $ev->IN_ISDIR ) {
                add_recursive_watch($file) if $ev->IN_ISDIR;
                send_sync( 'create_dir', $file );
            }

            # FILE Creation will be caught with close_write
        }

        if ( $ev->IN_CLOSE_WRITE ) {
            unless ( $file =~ m/\/\.pureftpd-(upload|rename)/ ) {
                send_sync( 'write', $file );
            }
        }

        if ( $ev->IN_DELETE ) {
            if ( $ev->IN_ISDIR ) {
                send_sync( 'delete_dir', $file );
            }
            else {
                send_sync( 'delete_file', $file );
            }
        }

        if ( $ev->IN_ATTRIB ) {
            my ( $mode, $uid, $gid ) = ( stat($file) )[ 2, 4, 5 ];
            send_sync( 'attrib', $file,
                sprintf( "%04o", $mode & 07777 ) . "|$uid|$gid" );
        }

        if ( $ev->IN_MOVED_FROM ) {
            $move_cookie = $ev->cookie;
            $move_source = $file
              if ( $file ne ''
                and ( !( $file =~ m/\/\.pureftpd-(upload|rename)/ ) ) );
            $kernel->delay_set( 'moved_from_rmtree', 2, $move_source,
                $move_cookie );
        }

        if ( $ev->IN_MOVED_TO ) {
            if ($move_source) {
                if ( $ev->IN_ISDIR ) {
                    add_recursive_watch($file);
                    send_sync( 'move_dir', $file, $move_source );
                }
                else {
                    unless ( $file =~ m/\/\.pureftpd-(upload|rename)/ ) {
                        send_sync( 'move_file', $file, $move_source );
                    }
                }
                $move_source = '';
            }
            else {
                if ( $ev->IN_ISDIR ) {
                    add_recursive_watch($file);
                    send_sync( 'create_dir', $file );
                }
                else {
                    send_sync( 'write', $file );
                }
            }
        }

    }

    $kernel->yield('send_notifications');

}

sub send_sync {
    my ( $or_type, $or_file, $or_filefrom ) = @_;
    $or_filefrom or $or_filefrom = "-";
    print "sync: $or_type for $or_file ($or_filefrom)\n";

    foreach my $module ( keys %$modules ) {
        send_module_sync( $module, $or_type, $or_file, $or_filefrom );
    }
}

sub file_part_of_module {
    my ( $module, $file ) = @_;
    my ( $path, $exclude ) = @{ $modules->{$module} }{ 'path', 'exclude' };

    if ( $file =~ m/^$path\/(.*)$/ ) {
        $file = $1;

        foreach my $pattern (@$exclude) {
            return if $file =~ m/^$pattern/;
        }

        return $file;

    }
    else {
        return;
    }
}

sub send_module_sync {
    my ( $module, $type, $file, $filefrom ) = @_;

    if ( $file = file_part_of_module( $module, $file ) ) {
        if ( $type eq 'move_dir' or $type eq 'move_file' ) {
            if ( $filefrom = file_part_of_module( $module, $filefrom ) ) {

                # ok just normal
            }
            else {
                $type = 'create';
            }
        }

    }
    elsif ( $filefrom = file_part_of_module( $module, $filefrom ) ) {

        # special case : this is a delete !
        $file = $filefrom;
        $type = 'rmtree';
    } else {
      # sorry not concerned
      return;
    }

    push @{ $module_queues->{$module} },
      "$type $file $filefrom " . time();

    # made simple because always starts at zero
    if (++$modules->{$module}->{log_curpos} > $log_max_size) {
       shift @{$module_queues->{$module}};
       $modules->{$module}->{log_start}++;
    }

}


$poe_kernel->run();
