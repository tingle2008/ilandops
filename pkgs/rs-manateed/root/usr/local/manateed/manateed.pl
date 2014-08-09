#!/usr/local/bin/perl5 -w
#
# New manateed
#

use strict;
use Tie::Syslog;
use File::stat;
use File::Slurp;
use vars qw/%handlers/;
use lib "/usr/local/manateed";
use OSDependant;
use YAML qw//;
use Sys::Hostname;
use POSIX;
use Time::HiRes qw/sleep/;

use constant MAINT    => '/home/seco/releases/bin/maint';
use constant MAINT_CF => '/home/seco/releases/conf/maint.cf';

sub trim($) {
    local $_ = shift;
    s/^\s+//;
    s/\s+$//;
    return $_;
}

sub be_nobody {
    my @nobody = getpwnam('nobody');
    die "ERROR: nobody $!\n" unless @nobody;
    $> = $< = $nobody[2];
    $) = $( = $nobody[3];
}

sub be_somebody {
    my ($who) = @_;
    my @somebody = getpwnam($who);
    die "ERROR: $who $!\n" unless @somebody;
    $> = $< = $somebody[2];
    $) = $( = $somebody[3];
}

sub invoke_cmd {
    my $cmd = shift;
    die "ERROR: Missing command" unless $cmd;

    local $_;
    my @args;
    foreach (@_) {
        if ($_) {
            die "ERROR: Illegal args: [$_]\n" unless m{^([,\w.=/:-]+)$};
            push @args, $1;
        } 
    }

    print `$cmd @args`;
}

sub log_msg($) {
    my $msg = shift;
    eval { print SYSLOG "$msg from IP: $ENV{'TCPREMOTEIP'}" };
}

sub handle_kidpd {
    my $killcmd = get_pkill_cmd();
    my $seconds_to_sleep = 20;
    if ($_[0]) {
        if ($_[0] =~ /^(\d+)$/) {
            $seconds_to_sleep = $1;
        }
    }

    if (-e "/export/crawlspace/searcher/clusterConfig/runscript.00") {
        # Plan G node - need to kill runscript.*
	system("rm -f /export/crawlspace/searcher/.autostart-runsearch;pkill -9 runscript;");
    } else {
	system("rm -f /export/crawlspace/searcher/.autostart-runsearch;$killcmd -9 runscript;");
    }
    if (proc_running("idpd")) {
        system("$killcmd idpd; sleep $seconds_to_sleep; $killcmd -9 idpd 2>/dev/null");
    } elsif (proc_running("proxy")) {
        system("$killcmd -9 runscript.00");
        system("$killcmd -9 runscript.01");
        system("$killcmd -9 runscript.02");
        system("$killcmd -9 runscript.03");
        system("$killcmd -9 proxy");
    } else {
        print "INFO: Could not find idpd or proxy running on this node.\n";
    }
}

sub handle_date {
    invoke_cmd("date");
}

sub ok_to_write_to {
    my $fs = shift;
    if ($fs !~ m{^([\w/]+)$}) {
        print "WARNING: skipping $fs\n";
    }
    $fs = $1;
    local *TMP;
    my @localtime = localtime;
    my $date = sprintf("%d%02d%02d.%02d%02d", 
        $localtime[5] + 1900,
        $localtime[4] + 1,
        $localtime[3], $localtime[2], $localtime[1]);

    my $name = "CHECKFS.$date.$$.TEST";
    open TMP, ">$fs/$name" or return;
    unlink "$fs/$name";
    print TMP "testing...\n" x 10 or return;
    close TMP or return;
    return 1;
}

sub handle_checkfs {
    local (*MTAB, $_);
    open MTAB, "/etc/mtab" or die "ERROR: mtab: $!\n";
    my ($mount_point, $fstype, $options);
    my $errors = 0;
    while (<MTAB>) {
       (undef, $mount_point, $fstype, $options) = split;
       next unless $fstype =~ "(?:ext[23]|xfs)";
       if ($options =~ /\brw\b/) {
            unless (ok_to_write_to($mount_point)) {
                print "ERROR: $mount_point: $!.\n";
                $errors++;
            }
        } else {
            print "WARNING: $mount_point is not mounted rw\n";
            $errors++;
        }
    }
    close MTAB;
    print "OK\n" unless $errors;
}

sub handle_checkfs2 {
    my $cmd = "/home/watcher/watcher3/util/check_fs";
    if (-x $cmd) {
      system $cmd;
    } else { 
      print "ERROR: Missing $cmd\n";
    }
}

sub handle_checkfserrors { 
my @patterns =  ( 'IO error syncing ext2 inode',
                       'EXT2-fs error \(device.*?\)',
                       'EXT3-fs: I/O error on journal device',
                       'EXT3-fs error \(device.*?\)',
                       'EXT3-fs \(device.*?\): panic forced after error',
                       '.*?: unrecoverable I/O read error',
                       'disabled mirror.*?\(errors detected\)',
                       'disabled device.*?\(errors detected\)',
                       'I/O Error Detected.  Shutting down filesystem:.*?',
                       'I/O error in filesystem \(.*?\)',
                       'Log I/O Error Detected.  Shutting down filesystem:.*?',
                       'I/O error: dev.*?, sector.*?',
                       'Input/output.*?error',
                       'I/O.*?error',
                       'bad.*?block',
                    );
    my @patex = map { qr /$_/ } @patterns;
    my $x = `dmesg`;
    foreach my $pattern ( @patex ) {
       if ( $x =~ m/($pattern)/) {
            print "ERROR: $1 \n";
        }
    }
}


sub handle_checkscsi {
    open(my $dmesg, "dmesg |") or die "ERROR: dmesg: $!\n";
    my %bad;
    while (<$dmesg>) {
	next unless
	  /SCSI disk error : host \d+ channel \d+ id (\d+)/ or
	  /scsi\d+: ERROR on channel \d+, id (\d+), lun \d+/ or
          /end request: I\/O error, dev (.*)\d+, sector \d+/  ;
	chomp;
	$bad{$1} = $_;
    }
    close($dmesg);

    print YAML::Dump(\%bad) if %bad;
}

sub handle_checkdisks {
    open(my $dmesg, "dmesg |") or die "ERROR: dmesg: $!\n";

    my %err;
    while (<$dmesg>) {
        chomp;
        m[SCSI disk error : host (\d+) channel (\d+) id (\d+)] and do {
            %err = (
                errortype => 'SCSI error', host => $1, channel => $2, id => $3, lun => undef,
                errstring => $&
            );
            last;
        };
        (m[scsi(\d+): ERROR on channel (\d+), id (\d+), lun (\d+)] or
         m[SCSI error : <(\d+) (\d+) (\d+) (\d+)> return code = (\S+)]) and do {
            %err = (
                errortype => 'SCSI error', host => $1, channel => $2, id => $3, lun => $4,
                errstring => $& 
            );
            last;
        };

        # handle I/O errors
        (m[I/O error in filesystem (.*)] or
         m[I/O error: dev (.*)\d*, sector \d+]) and do {
            %err = (
                errortype => 'I/O error', disk => $1, errstring => $&
            );
            last;
        };

        # handle FS errors
        (m[inode bitmap error for orphan] or
         m[EXT3-fs error \(device .+\): .+:] or
         m[EXT3-fs panic from previous error] or
         m[EXT3-fs \(device .+\): panic forced after error] or
         m[EXT3-fs error \(device .+\) in .+: .+] or
         m[EXT3-fs: I/O error on journal device]) and do {
            %err = (
                errortype => 'FS error', errstring => $&
            );
            last;
        };
    }
    close $dmesg;
    print YAML::Dump(\%err) if (keys %err);
}


sub handle_dmesg {
    open(my $dmesg, "dmesg |") or die "ERROR: dmesg: $!\n";
    while (<$dmesg>) {
	print;
   }
}


sub handle_checkdf {
  my %check;
  if (scalar @_) {
     print "\@_ = @_\n";
     %check = @_;
  } else {
     $check{"/"}=95;
     $check{"/export/crawlspace"}=98;
     $check{"/export/home"}=95;
  }
  my @df = `df -k`;
  my $errors=0;
  foreach(@df) {
    my ($fs,$blocks,$used,$avail,$use,$mount) = split(/\s+/,$_);
    if ((defined $mount) && (exists $check{$mount})) {
       $use =~ s/\%//;
       if ($use >= $check{$mount}) {
          print "ERROR: $mount = $use\% full\n";
          $errors++;
       }
    }
  }
  print "OK\n" unless ($errors);
}



sub handle_check {
    local $_;
    my $extended_check = (defined $_[0] && $_[0] =~ /^-E$/);
    my $ec = "/export/crawlspace";
    my $hostname = `hostname`; chomp $hostname;
    my $user  = "searcher";
    my $checkidpd  = 0;
    my $warnings = 0;
    my $multihead = 0;
    my $release = "";
    my $idpd = "";
    my @idpds = ();

    sub dbinfo {
     my($label,$dbname) = @_;
     my $r = readlink $dbname || "MISSING";
     print "$label:$r\n";
     if (open(CDX,"$dbname/database.version")) {
       my $x;
       $x = <CDX>;
       $x = <CDX>;
       $x = <CDX>;
       if ($x =~ m/cdxcore-([\d\.]+)~/) {
         print "cdx-$label:$1\n";
       } else {
         print "cdx-$label:MISSING\n";
       }
       close  CDX;
     }
     return $r;
    }


    my @checkexist  = (
         "$ec/searcher/Release/.",
         "$ec/searcher/clusterConfig/.",
         "$ec/searcher/clusterConfig/clusterAccess.tcl",
         "$ec/Current-database/.");

    if ($hostname =~ m/^(goo|i|c|x|b)\d+/) {
         push(@checkexist,(
             "$ec/searcher/myrinet/.",
             "$ec/searcher/myrinet/lam_config",
             "$ec/searcher/Release/bin/idpd" ));
         $checkidpd = 1;
    }

    # Check for multi-headedness
    foreach my $head ("00".."03") {
        if (-e "$ec/searcher/clusterConfig/runscript.$head") {
            push(@idpds,"$head");
            $multihead++;
        }
    }


    $_ = dbinfo("Current-database", "$ec/Current-database");

    dbinfo("Rollback-database", "$ec/Rollback-database");
    dbinfo("Setlive-database", "$ec/Setlive-database");
    dbinfo("Buddy-database", "$ec/Buddy-database");

    if ($multihead) {
	# Plan G, multi-IDPD
	foreach $idpd (@idpds) {
		dbinfo("Current-database ($idpd)","$ec/idpds/$idpd/Current-database");
#		$_ = readlink "$ec/idpds/$idpd/Current-database" || "MISSING";
#		print "Current-database ($idpd):$_\n";
	}
    }

    if ($hostname =~ m/^p/) {
    }



    # Extended Database Checkup,  anyone?
    handle_comparedb() if $extended_check;

    $_ = readlink "$ec/$user/Release" || "MISSING";
    print "Release:$_\n";
    $_ = readlink "$ec/$user/clusterConfig" || "MISSING";
    print "clusterConfig:$_\n";
    $_ = readlink "$ec/$user/myrinet" || "MISSING";
    print "myrinet:$_\n";
    $_ = readlink "$ec/$user/Election" || "MISSING";
    print "Election:$_\n";

    $_ = readlink "$ec/$user/libmlr" || "MISSING";
    print "libmlr:$_\n";

    $_ = readlink "$ec/$user/mlrmodels" || "MISSING"; # bz 2383891
    print "mlrmodels:$_\n";

    $_ = readlink "$ec/$user/libyell" || "MISSING";
    print "libyell:$_\n";

    $_ = readlink "$ec/$user/libspeller" || "MISSING";
    print "libspeller:$_\n";

    if (-d "$ec/$user/Release/.") {
      $_ = readlink "$ec/$user/Release/Broken";
      print "Release/Broken:$_\n" if (defined $_);
    }

    # Do all existance-type checks.
    for my $file (@checkexist) {
         unless (-e $file) {
             $warnings++;
             print "Warning: missing $file\n"
         }
    }

    # Check IDPD setuid
    if ($checkidpd) {
        if (-e "$ec/$user/Release/bin/idpd") {
            my $st = stat("$ec/$user/Release/bin/idpd");
            unless (($st->mode & 04111) == 04111) {
                print "Warning: idpd is either not setuid root or not executable (needs mode 4111)\n" ;
                $warnings ++;
            }
            unless ($st->uid == 0) {
                print "Warning: idpd is not owned by root\n" ;
                $warnings ++;
            }
        } else {
            print "Warning: idpd not found!\n";
            $warnings ++;
        }
    }

    print "Warning: No warnings found.\n" unless $warnings;
}

sub handle_checkcrawler {
	my $releases = "/export/crawlspace/crawler";
	my %files;
	my $file;
	opendir(DIR, $releases) || die "Can't opendir $releases: $!" ;
	while ( defined ($file = readdir(DIR) )  ) {
		if (-l "$releases/$file" ) { 
			$files{$file} = readlink("$releases/$file");
		}
	}
	closedir DIR;

	foreach my $i (keys %files) {
		print "$i:$files{$i}\n";
	}
}

sub handle_db_fresh {
    local $_;

    my @files = qw(/export/crawlspace/Current-database/database.docindex
        /home/searcher/Current-database/database.docindex
        /export/crawlspace/Current-database/database.docindex/big-file-marker);

    my $db;
    for (@files) {
        $db = $_, last if -f;
    }

    unless ($db) {
        print "no db file found\n";
        return;
    }

    print((-M $db) * 86400, "\n");
}

sub handle_df {
    local $_ = shift;
    my $fs = "";
    if ($_) {
        die "ERROR: Illegal argument\n" unless m{^([\w./-]+)$};
        $fs = $1 if -e $1;
    }
    invoke_cmd("df", "-lk", "$fs");
}

sub handle_findpanic {
    my $time = shift;
    if (defined($time) && $time =~ /^(\d+)$/) {
        $time = $1;
    } else {
        $time = "";
    }
    invoke_cmd("/usr/local/bin/findpanic", $time);
}

sub handle_comparedb {
    invoke_cmd("/usr/local/bin/comparedb");
}

sub get_load_avg() {
    my $uptime = `uptime`;
    my $load_avg = ($uptime =~ /average: (\d+(?:\.\d+))/)[0];
    return $load_avg * 100;
}

sub get_free_disk() {
    local $_;
    local *DF;
    open DF, "df -kl|" or die "ERROR: df: $!\n";
    my ($gtotal, $gavail);
    while (<DF>) {
        next unless m{^/dev};
        my ($total, $avail);
        (undef, $total, undef, $avail) = split;
        $gtotal += $total; $gavail += $avail;
    }
    close DF or die "ERROR: closing df\n";
    return 100.0 * (1 - $gavail/$gtotal);
}

sub handle_getMonitorStats {
    printf "CPU_LOAD%%=%.2f FREE_MEM%%=%.2f FREE_DISK%%=%.2f DISK_BUSY%%=%d\n", 
        get_load_avg(), get_free_mem(), get_free_disk(), get_disk_busy()
}

sub handle_hostname {
    invoke_cmd("hostname");
}

sub handle_iostat {
    invoke_cmd("iostat", split(' ', '-x 10 2'));
}

sub handle_ip {
    local $_;
    local $/ = "";
    local *IFCONFIG;

    open IFCONFIG, "/sbin/ifconfig -a |" or die "ERROR: ifconfig: $!\n";
    while (<IFCONFIG>) {
        my ($iface, $descr) = split ' ', $_, 2;
        next if $iface eq 'lo';
        next unless $descr =~ /\bUP\b/;
        next unless $descr =~ /addr:(\d+\.\d+\.\d+\.\d+)/;
        print "$iface $1\n";
    }
    close IFCONFIG or die "ERROR: closing ifconfig: $!\n";
}

# TODO: check owner
sub handle_kill {
    return unless @_;
    my $signal = 15;
    if ($_[0] && $_[0] =~ /^-(\d+)$/) {
        $signal = $1;
        shift;
    }

    if ($_[0] =~ /^(\d+)$/) {
        my $pid = $1;
        return unless $pid > 1;
        kill $signal, $pid;
    }
}

sub handle_killp {
    local $_;
    my %killable_users;
    @killable_users{qw(smchttp crawler searcher inkops seco rrd)} = ();
    
    return unless @_;
    my $signal = 15;
    if ($_[0] && $_[0] =~ /^-(\d+)$/) {
        $signal = $1;
        shift;
    }

    return unless $_[0];
    my $pattern = ($_[0] =~ /^([\w._-]+)$/)[0];
    return unless $pattern;

    local *PS;
    open PS, "ps -ef | grep '$pattern' | grep -v grep | grep -v manateed|"
        or die "ERROR: killp: $!\n";
    while (<PS>) {
        my ($user, $pid_tainted) = split;
        next unless ((exists $killable_users{$user}) || (/aalg/));
        print ">>>$_";
        $pid_tainted =~ /^(\d+)$/;
        kill $signal, $1 or warn "kill: $!";
    }
    close PS;
}

sub private_ps {
    my ($ps_cmd, $pattern) = @_;
    return unless $ps_cmd;

    $pattern ||= '.';
    local $_;
    local *PS;
    open PS, "$ps_cmd|" or die "ps: $!\n";
    while (<PS>) {
        print if /$pattern/;
    }
    close PS or die;
}

sub handle_ps {
    private_ps("ps -eo user,s,rss,vsz,pmem,pcpu,stime,comm", shift);
}

sub handle_psef {
    private_ps("ps -ef", shift);
}

sub handle_maint {
    require Seco::Range;
    my @arg = @_;
    my ($maint, $maint_cf) = (MAINT, MAINT_CF);
    my $hostname = hostname();

    die "ERROR: $hostname: I am not a maint admin\n"
      unless(grep { $_ eq $hostname } Seco::Range::expand_range('@MAINT'));
    die "ERROR: $maint: $!\n"    unless (-x $maint);
    die "ERROR: $maint_cf: $!\n" unless (-r $maint_cf);
    die "ERROR: maint <args>\n"  unless (@arg);

    if ($arg[0] eq 'pending_add') {
	my $cluster = ($arg[1]) ? $arg[1] : '';
	my %pending;
	open(my $cmd, "$maint -l $cluster 2>&1 |") or die "$maint: $!\n";
	while (<$cmd>) {
	    chomp;
	    next unless my ($cluster, $node) = /^\s+(\S+)\s.*Add (\S+)\s?.*$/;
	    push(@{ $pending{$cluster} }, $node);
	}
	close($cmd);

	foreach my $cluster (keys %pending) {
	    @{ $pending{$cluster} } =
	      Seco::Range::sorted_expand_range(join(',', @{ $pending{$cluster} }));
	}

	print YAML::Dump(\%pending) if (%pending);
    }
    elsif ($arg[0] eq 'known_clusters') {
	my %clusters;
	open(my $cmd, "$maint --clusters 2>&1 |") or die "$maint: $!\n";
	while (<$cmd>) {
	    next unless my ($cluster) = /^\s+(\S+)/;
	    next if exists($clusters{$cluster});
	    next unless Seco::Range::expand_range('%' . $cluster);
	    $clusters{$cluster}++;
	}
	close($cmd);

	my @clusters = sort keys %clusters;
	print YAML::Dump(\@clusters);
    }
    else {
	die "ERROR: '$arg[0]': unknown param\n";
    }
}

sub handle_searcher {
    my $arg = shift;
    die "ERROR: need start or stop argument for searcher.\n" unless $arg;
    return unless $arg =~ /^(start|stop|test|zap|rootstart|megazap)$/i;

    if ($arg eq "megazap") {
       handle_searcher("stop");
       # ntpdate first kills the running ntpd, and then restarts
	if (-x "/etc/service/ntpd/ntpdate-now") {
		system("/etc/service/ntpd/ntpdate-now");
	} elsif (-x "/usr/local/bin/ntpdate-now") {
		system("/usr/local/bin/ntpdate-now");
        } else { 
	       system("/etc/init.d/ntpdate", "start");
        }
       handle_ipcrmall();
       handle_searcher("start");
       return;
    }

    unless (-x "/etc/init.d/runsearch") {
        print "no init found\n";
        return;
    }
    
    my $autostart = "/export/crawlspace/searcher/.autostart-runsearch";
    if ($arg eq 'start' || $arg eq 'test') {
        unlink("/export/crawlspace/searcher/Release/Broken");
        open AUTOSTART, ">$autostart" or 
            die "ERROR: couldn't touch $autostart: $!\n";
        close AUTOSTART;
        invoke_cmd("/etc/init.d/runsearch", "forcestart");
        if ($arg eq 'test') {
            unlink $autostart or die "ERROR: couldn't remove $autostart: $!\n";
        }
    } elsif ($arg eq 'stop') {
        handle_kidpd();
    } elsif ($arg eq 'zap') {
        handle_zapmws();
    } elsif ($arg eq 'rootstart') {
        open AUTOSTART, ">$autostart" or 
            die "ERROR: couldn't touch $autostart: $!\n";
        close AUTOSTART;
        invoke_cmd("/export/crawlspace/searcher/Release/bin/runscript","-daemon");
    }
}

sub handle_thumb {
    my $arg = shift;
    die "ERROR: need start or stop argument for thumb.\n" unless $arg;
    return unless $arg =~ /^(start|stop|test|zap|rootstart|megazap)$/i;

    if ($arg eq "megazap") {
       handle_thumb("stop");
       # Anything else you want to happen in-between goes here
       handle_thumb("start");
       return;
    }

    unless (-x "/etc/init.d/runthumb") {
        print "no init found\n";
        return;
    }
    
    my $autostart = "/local1/thumb/.autostart-runthumb";
    if ($arg eq 'start' || $arg eq 'test') {
        open AUTOSTART, ">$autostart" or 
            die "ERROR: couldn't touch $autostart: $!\n";
        close AUTOSTART;
        invoke_cmd("/etc/init.d/runthumb", "start");
        if ($arg eq 'test') {
            unlink $autostart or die "ERROR: couldn't remove $autostart: $!\n";
        }
    } elsif ($arg eq 'stop') {
        invoke_cmd("/etc/init.d/runthumb", "stop");
        unlink $autostart or die "ERROR: couldn't remove $autostart: $!\n";
    } elsif ($arg eq 'zap') {
        invoke_cmd("/etc/init.d/runthumb", "restart");
    } elsif ($arg eq 'rootstart') {
        open AUTOSTART, ">$autostart" or 
            die "ERROR: couldn't touch $autostart: $!\n";
        close AUTOSTART;
        invoke_cmd("/local1/thumb/bin/niv_thumbserver","-cfg","/local1/thumb/conf/thumb_80.cfg");
    }
}

sub handle_tail {
    return unless @_;

    be_nobody() unless $>;
    my $lines = 10;
    if ($_[0] =~ /^-(\d+)$/) {
        $lines = $1;
        shift;
    }

    my $file = shift;
    return unless defined $file and -r $file and $file =~ m{^([\w_./-]+)$};
    $file = $1; # untaint
    my $cmd = "tail -$lines $file";
    my $out = `$cmd`;
    $out .= "\n" unless ($out =~ m/\n$/);
    print $out;
}

sub handle_teebridge {
    my $arg = shift;
    die "ERROR: need start or stop argument for teebridge.\n" unless $arg;
    return unless $arg =~ /^(start|stop)$/i;

    be_somebody('searcher');

    if ($arg eq 'start') {
	handle_teebridge('stop');
        invoke_cmd('/export/crawlspace/searcher/Release/bin/runtee', '-daemon');
    }
    elsif ($arg eq 'stop') {
	my $killcmd = get_pkill_cmd();
	if (proc_running('runtee')) {
	    system("$killcmd -9 runtee");
	}
	if (proc_running('teebridge')) {
	    system("$killcmd -9 teebridge");
	}
    }
}

sub handle_uptime {
    invoke_cmd("uptime");
}

sub handle_version {
    print `cat /usr/local/manateed/VERSION`;
}

sub handle_vip {
    my ($tainted_vip, $tainted_cmd, $tainted_iface) = @_;
    my ($vip, $cmd, $iface);    # untainted versions of the above
    
    return unless $tainted_vip and $tainted_vip =~ /^(\d+\.\d+\.\d+\.\d+)$/;
    $vip = $1;

    return unless $tainted_cmd and $tainted_cmd =~ /^(up|down)$/;
    $cmd = $1;

    $iface = "";
    $iface = $1 if defined $tainted_iface and $tainted_iface =~ /^([\w:]+)$/;

    invoke_cmd("./tools/$^O_vip.pl", $vip, $cmd, $iface);
}

sub handle_wait {
    my $t_seconds = shift; # tainted
    my $seconds = 10;
    $seconds = $1 if defined $t_seconds and $t_seconds =~ /^(\d+)$/;
    sleep $seconds;
}

sub handle_watcher {
    my $action="";
    my $name="";
    my $size =  scalar @_;
    die "usage: watcher (start|stop|sleep|tempsleep|restart|kill) name" unless ((scalar @_) == 2);
 
    my $arg = shift;
    if ($arg =~ m/^(start|stop|sleep|restart|kill|tempsleep)$/) {
       $action = $1;
    } else { 
       die "bad action";
    }

    $arg = shift;
    if ($arg =~ /^([a-z0-9_-]+)$/i) {  
      $name = $1;
    } else {
     die "bad name";
    }
	
    be_somebody("watcher")
        unless(-d "/service/watcher-$name");

    my $command = "/home/watcher/watcher3/bin/$action";

    unless (-x $command) {
        print "ERROR: missing $command\n";
        return;
    }
    print "$command $name\n";
    chdir "/home/watcher/watcher3";
    invoke_cmd($command,$name);
}


sub handle_dbtypes {
    local *DBTYPES;
    my $dbtypes_path = "/export/crawlspace/Current-database/database.dbtypes";
    open DBTYPES, $dbtypes_path or die "ERROR: can't open $dbtypes_path: $!\n";
    my %dbtype_found;
    while (<DBTYPES>) {
        /^dbsel:(.+)$/ and $dbtype_found{$1}++;
    }
    close DBTYPES or die;

    if (%dbtype_found) {
        print join ",", sort keys %dbtype_found;
    } else {
        print "ERROR: no databases defined";
    }
    print "\n";
}

sub handle_adddbtype {
    my $t_dbtype = shift; # tainted
    die "ERROR: No dbtype specified\n" unless defined $t_dbtype;

    die "ERROR: invalid chars in dbtype." unless $t_dbtype =~ /^([\w-]+)$/;
    my $dbtype = $1;
    system("/home/seco/candy/bin/make-dbtypes-have", $dbtype) == 0 
        or print "ERROR: $? - $!\n";
}

sub handle_refreshfields {
    my $hostname = `hostname`;
    my $dbtype = "bow";
    $dbtype = "gd -numlz 40 -lzbase 3001" if $hostname =~ /^i3[01]\d\d$/;
    print "dbtype: $dbtype\n";
    my $grabdb = "/home/crawler/tools/bin/grabdb";
    die "ERROR: not executable $grabdb\n" unless -x $grabdb;
    system("su","crawler","-c","/home/crawler/tools/bin/grabdb -readcurrent -t -srcprefix $dbtype -fromsnapshot -refreshonly") == 0
        or die "ERROR: grabdb - $!\n";
}

sub handle_netstatport {
    my $port = 55555;
    my $t_port = shift;
    $port = $1 if defined $t_port and $t_port =~ /^(\d+)$/;
    print "INFO: running ./tools/netstat.pl --port=$port\n";
    invoke_cmd("./tools/netstat.pl", "--port=$port");
}

sub handle_netstat {
    invoke_cmd("./tools/netstat.pl");
}

sub handle_ttcp {
    invoke_cmd("ttcp", @_);
}

sub handle_uname {
    invoke_cmd("uname",@_);
}

sub handle_ping {
    die "ERROR: need host.\n" unless @_;
    my $extra_args = "-b 1400 -B 2 -c 100 -p 1000 -q";
    invoke_cmd('fping', split(' ', $extra_args), @_);
}

sub handle_lastvam {
    invoke_cmd("/usr/local/bin/lastvam");
}

sub handle_lastidpd {
    invoke_cmd("/usr/local/bin/lastidpd");
}


sub handle_ndcreload {
    my $rsyncdns = "/usr/local/bind/sbin/rsyncdns";
    my $ndcreload = "/usr/sbin/ndc reload";
    my $cmd = -x $rsyncdns ? $rsyncdns : $ndcreload;

    fork and exit 0;
    close STDIN; close STDOUT; close STDERR;
    system $cmd;
}

# wtf is this?
sub handle_ndccheck {
    system "touch", "/tmp/.update";
    print "ok\n";
}

sub handle_tagchk {
    invoke_cmd("./tools/tagchk.pl");
}

sub handle_ntpqrv {
    invoke_cmd("ntpq", "-c", "rv");
}

sub handle_unixtime {
    print "unixtime=" . time . "\n";
}


sub handle_lzpath {
    my $current_db = readlink "/export/crawlspace/Current-database";
    die "Current-database: $!" unless $current_db;

    open GRABDB, "/export/crawlspace/grabdb.$current_db" or
        die "ERROR: grabdb.$current_db: $!\n";
    local $_; local *GRABDB;
    while (<GRABDB>) {
        next unless /^Grabbing (lz\d+::\S*)\s+\.\.\./;
        print "$1\n";
        return;
    }
    close GRABDB or die "$!";
    print "ERROR: no match for pattern\n";
}

sub handle_sesymlink {
    local $_;
    my @valid_args;
    foreach (@_) {
        my $valid_arg = m{^((?:config|myrinet|database|release|crawler|perm|election|libmlr|mlrmodels|libyell|libspeller)=[:,\w_./-]+)$};
        if ($valid_arg) {
            push @valid_args, "--$1";
        } else {
            die "ERROR: bad syntax 'sesymlink $_'\n";
        }
    }
    invoke_cmd("./tools/sesymlink.pl", @valid_args);
}

sub handle_perm {
	invoke_cmd("./tools/perm.pl", @_);
}

sub handle_help {
    my $arg = shift;
    return unless $arg and $arg eq "please";
    print join(",", sort keys %handlers), "\n";
}

sub handle_zap {
    my $zapper = shift;
    die "zap what?" unless $zapper && $zapper =~ /^(\w+)$/;
    $zapper = "./tools/zap/$1";
    die "ERROR: The manateed does not know how to zap $1\n"
        unless -x $zapper;
    my @args = ();
    my $signal = shift;
    if ($signal) {
        die "ERROR: Invalid signal." unless $signal =~ /^-(\d+)$/;
        push @args, $1;
    }
    invoke_cmd($zapper, @args);
}

sub handle_zapmws {
    my $signal = proc_running('proxy') ? 9 : 15;
    my $seconds_to_sleep = 20;
    if ($_[0]) {
        if ($_[0] =~ /^-(\d+)$/) {
            $signal = $1;
        } elsif ($_[0] =~ /^(\d+)$/) {
            $seconds_to_sleep = $1;
        }
    }

    local $_;
    open PS, "ps -ef | grep -v grep | egrep 'minihttpd|idpd|proxy'|" or die $!;
    my @pids;
    while (<PS>) {
        next unless /(?:idpPort 55555|proxy.cfg)/;
        my $pid = (split)[1];
        $pid =~ /^(\d+)$/ or die "WTF?: $pid";
        $pid = $1;
        push @pids, $pid;
    }

    if (@pids) {
        kill $signal, @pids;
        sleep $seconds_to_sleep;
        kill 9, @pids;
        print scalar @pids, " processes killed.\n"
    } else {
        print "no process matched\n" unless @pids;
    }
}

sub find_backend_device {
    my $cfg = "/export/crawlspace/searcher/clusterConfig/cluster.tcl";
    my $device;
    open CFG, $cfg or die "ERROR: $cfg $!\n";
    while (<CFG>) {
        m{SeRegSetString\s+/env/IEAM_DEVICE\s+(\S+)} or next;
        $device = $1;
        last;
    }
    close CFG;
    return $device;
}

sub handle_restart_gige {
    $^O eq 'linux' or die "ERROR: only supported on linux.\n";
    die "ERROR: idpd is running on this machine.\n"
        if proc_running('idpd');

    my $eth_device = find_backend_device();
    die "ERROR: no IEAM_DEVICE found\n" unless $eth_device;

    my $output = `ifdown $eth_device 2>&1 && rmmod e1000 2>&1 && ifup $eth_device 2>&1`;
    if ($? == 0) {
        print "OK\n";
    } else {
        $output =~ s/\n/ | /;
        die "ERROR: $output\n";
    }
    write_gige_status($eth_device); # reset error counters
}

sub write_gige_status {
    my $eth = shift;
    open STAT, ">/var/log/gige_stats.log" or 
        warn "ERROR: /var/log/gige_stats.log: $!\n" and return;
    print STAT "LastUpdate ", time, "\n";

    open ETH, "</proc/net/PRO_LAN_Adapters/$eth.info" or 
        die "ERROR: $eth: $!\n";
    while (<ETH>) {
        next unless /Err/;
        print STAT $_;
    }
    close ETH;
    close STAT;
}

sub print_readdir_header {
    print "# file:link:dev:ino:mode:nlink:uid:gid:rdev:size:atime:mtime:ctime:blksize:blocks\n";
}

sub print_readdir_entry {
    my $file = shift;
    my @stat = CORE::lstat($file);
    return unless defined $stat[0]; # no dev?
    my $link = readlink($file) || "";
    unshift @stat, $file, $link;
    print join(":", @stat), "\n";
}

sub handle_readdir {
    return unless @_;
    my $quiet = ($_[0] =~ /^-q$/) and shift;
    be_nobody() unless $>;
    
    print_readdir_header() unless $quiet;
    
    for my $dir (@_) {
        next unless -d $dir;
        opendir DIR, $dir or print "WARNING: $dir $!\n" and next;
        $dir = "" if $dir eq "/";
        while (my $filename = readdir(DIR)) {
            my $file = "$dir/$filename";
            print_readdir_entry($file);
        }
        closedir DIR;
    }
}

sub handle_ls {
    # Do this as nobody
    be_nobody() unless $>;
    print_readdir_header();

    for my $arg (@_) {
        foreach my $file (glob($arg)) {
            if (-d $file) {
                handle_readdir("-q", $file);
            } else {
                print_readdir_entry($file);
            }
        }
    }
}


sub handle_readlink {
    # Do this as nobody
    be_nobody() unless $>;
    for my $arg (@_) {
        my $rl = readlink $arg;
        $rl ||= "ERROR:$!";
        print "${arg}:$rl\n";
    }
}



sub handle_md5 {
    # Do this as nobody
    be_nobody() unless $>;
    
    eval ' use Digest::MD5; ' ;

    if (-d $_[0]) {
      @_ = glob($_[0] . "/*");
    }

    for my $arg (@_) {
        next unless (-f $arg);
        my $ctx = Digest::MD5->new;
	my $size = -s $arg;
	if (open(FILE,"<$arg")) {
		$ctx->addfile(*FILE);
		my $digest = $ctx->hexdigest;
		print "$digest\t$arg\n";
	} else {
		print "missing\t$arg\n";
	}
	close FILE;
    }
}



sub handle_proxyramusage {
    my $max = -1;
    open PS, "ps -O 'rssize' --no-headers -usearcher -C proxy|" or
        die "ERROR: ps $!\n";
    while (<PS>) {
        my $size = (split)[1];
        $max = $size if $size > $max;
    }
    print "$max\n";
}

sub handle_fixcore {
    my $i = (chmod 0644, "/export/crawlspace/searcher/Release/found.core");
    print "$i files changed\n";
}


sub handle_ipcrmall {
 my $idp_dir = "/export/crawlspace/searcher/Release/bin";
 unless (-x "$idp_dir/idpd" || -x "$idp_dir/proxy") {
   print "Warning: Not an idpd node\n";
   return 1;
 }

 open(IPCS,"ipcs -m|");
 while(<IPCS>) {
   if (/0x[0-9a-f]{8} (\d+)/) {
      my $id = $1;
      my $cmd = "ipcrm shm $id";
      system $cmd;
   }
 }
 close IPCS;
}

sub handle_3winfo {
    sub find_twcli {
        my @possible = qw(
                        /usr/sbin/tw_cli
                        /usr/local/sbin/tw_cli
                        /home/jfesler/bin/tw_cli);
        foreach my $tw (@possible) {
            return $tw if -x $tw;
        }
        die "ERROR: no tw_cli on thix box\n";
    }
    my $tw_cli = find_twcli();
   
    my $verbose = @_ && $_[0] eq '-v';
    my $yaml = @_ && $_[0] eq '-y';

    # find the controller
    my $not_ok = "";
    my @controllers;
    my @units;
    my @ports;
    my %hashie;
    open my $pipe, "$tw_cli info|" or die "ERROR: tw_cli: $!";
    while (<$pipe>) {
        chomp;
        next unless /^c\d/;
        my ($ctl, $model, $ports, $drives, $units, $notopt, $rrate,
            $vrate, $bbu) = split /\s+/;
        $ctl =~ /^(c\d+)$/ or die "Controller $ctl doesn't look like c0-9";
        $ctl = $1;

        foreach (qw/firmware bios monitor serial pcb pchip achip/) {
            my $cmd = "$tw_cli info $ctl $_";
            open my $pipetemp, "$cmd|" or die "ERROR: tw_cli: $!";
            my $out = <$pipetemp>;
            close $pipetemp;
            chomp $out;
            $out =~ m/= (.*)/;
            $hashie{$ctl}->{$_} = $1;
        }

        $hashie{$ctl}->{model} = $model;
        $hashie{$ctl}->{units} = {};
        open my $p2, "$tw_cli info $ctl|" or die "ERROR: tw_cli: $!";
        while(<$p2>) {
            chomp;
            if(/^u(\d)/) {
                my ($unit, $type, $status, $cmpl, $stripe, $size,
                    $cache, $verify, $ignecc) = split /\s+/;

                $hashie{$ctl}->{units}->{$unit} = { type => $type,
                                                    status => $status,
                                                    cmpl => $cmpl,
                                                    stripe => $stripe,
                                                    size => $size,
                                                    cache => $cache,
                                                    verify => $verify,
                                                    ignecc => $ignecc };

                $not_ok .= "BAD:$ctl$unit\n" unless ($status eq 'OK');
            } elsif(/^p(\d)/) {
                my ($port, $status, $unit, $size, $gb, $blocks, $serial) =
                    split /\s+/;
                $port =~ /^(.*)$/;
                $port = $1;
                $unit =~ /^(.*)$/;
                $unit = $1;
                $not_ok .= "BAD:$ctl$unit:$port\n" unless ($status eq 'OK');
                my ($modstr) =
                    ((`$tw_cli info $ctl $port model`)[0]);
                $modstr =~ s/.*= //;
                $modstr =~ s/^ST3/Seagate /;
                chomp $modstr;
                my ($make, $model) = split /\s/, $modstr;
                $hashie{$ctl}->{disks}->{$port} = { status => $status,
                                                    unit => $unit,
                                                    size => $size,
                                                    blocks => $blocks,
                                                    serial => $serial,
                                                    make => $make,
                                                    model => $model
                };


            }
        }
        close $p2;
    }
    close $pipe;
   if($verbose) {

        foreach my $ctl (keys %hashie) {
            print uc join "|", ($ctl,
                                $hashie{$ctl}->{model},
                                $hashie{$ctl}->{firmware},
                                $hashie{$ctl}->{bios},
                                $hashie{$ctl}->{monitor},
                                $hashie{$ctl}->{serial},
                                $hashie{$ctl}->{pcb},
                                $hashie{$ctl}->{pchip},
                                $hashie{$ctl}->{achip});
            print "\n";

            my $units = $hashie{$ctl}->{units};
            my $disks = $hashie{$ctl}->{disks};
            foreach my $uname (sort { ((($a =~ /(\d+)/)[0]) <=>
                                       (($b =~ /(\d+)/)[0])) }
                               keys %$units) {
                my $unit = $units->{$uname};
                print uc join "|", ($ctl, $uname,
                                    $unit->{status},
                                    $unit->{type},
                                    $unit->{size});
                print "\n";
                foreach my $dname (sort { ((($a =~ /(\d+)/)[0]) <=>
                                           (($b =~ /(\d+)/)[0])) }
                                   keys %$disks) {
                    next unless $disks->{$dname}->{unit} eq $uname;
                    my $disk = $disks->{$dname};
                    my $portnum = $dname;
                    $portnum =~ s/p//;
                    print uc join "|", ($portnum,
                                        $disk->{make},
                                        $disk->{model},
                                        $disk->{serial},
                                        $disk->{size},
                                        $disk->{status});
                    print "\n";
                }
            }
        }
    }

    if($yaml) {
        print YAML::Dump(\%hashie);
        return;
    }

    unless ($verbose) {
        $not_ok ||= "OK";
        print "$not_ok\n";
    }
}

sub handle_timeoffset {
    my $arg = shift;
    die "ERROR: need start or stop argument for searcher.\n" unless $arg;
    return unless $arg =~ /^(up|down|restore)$/i;

    system("/etc/init.d/ntpdate","stop");
    if ($arg eq "restore") {
      system("/usr/bin/ntpdate","ntpsc1");
      return;
    }

my $command = <<'EOF' ;
use Time::HiRes qw(usleep gettimeofday);
use POSIX qw(strftime);
use strict;

my $million = 1000000;

 my ($seconds, $microseconds) = gettimeofday;
 my $delay = $million - $microseconds ;

 if ($arg eq "up") {
   $delay -= ($million / 8);
 } else {
   $delay += ($million / 8);
 }
 if ($delay < 0) { $delay += $million; } 

 usleep($delay);

 ($seconds, $microseconds) = gettimeofday;
 print "point a: $seconds $microseconds\n";
 $seconds++ if ($microseconds > ($million / 2));
 my $string = strftime("%m%d%H%M%Y.%S",localtime $seconds);
 system "date $string\n";
 ($seconds, $microseconds) = gettimeofday;
 print "point a: $seconds $microseconds\n";
EOF

    eval $command;
    print $@ if $@;
    die if $@;
    print "We are now checking to see how off we are\n";
    system("ntpdate -b -q ntpsc1");
    print "done\n";
}

sub handle_kernel {
    my $kernel_release = (uname())[2];
    print "$kernel_release\n";
}

sub this_is_an_HP {
    my $result;
    open my $fh, "<", "/etc/lilo.conf" or warn "ERROR: lilo.conf: $!"
        and return;
    while (<$fh>) {
        next unless m{/dev/cciss};
        $result = 1;
        last;
    }
    close $fh;
    return $result;
}

sub find_serial_port {
    my $result;
    open my $fh, "<", "/etc/lilo.conf" or warn "ERROR: lilo.conf: $!"
        and return;
    while (<$fh>) {
        next unless /tty(S\d),/;
        $result = "/dev/tty$1";
        last;
    }
    close $fh;
    return $result;
}

sub handle_phantom_label {
    my $msg;
    if (this_is_an_HP()) {
        print "ERROR: Not valid on HP boxes\n";
        return;
    }

    $msg = @_ ? join(' ', @_) : "OK";
    my $device = find_serial_port();
    my $hostname = hostname();
    open my $fh, ">", $device or warn "ERROR: opening $device: $!\n";
    send_slow($fh, "\nLCD:\n$hostname\n$msg\n");
    close $fh;
    system("killall getty 2>/dev/null");
    print "OK\n";
}

sub send_slow {
    my ($fh, $msg) = @_;
    for (split //, $msg) {
        syswrite($fh, $_);
        sleep(0.1);
    }
}

sub disk_model_info {
	return undef unless -f '/proc/scsi/scsi';
	my $scsi = read_file('/proc/scsi/scsi');
	my ($vendor, $model) = $scsi =~ /Vendor: (\S+)\s+Model: (\S+)/ig;
	return undef unless defined $model and $model;
	return $model;
}
sub cpu_info {
    local $_ = `dmidecode`;
    die "Can't run dmidecode: $!" if ($? != 0);

    my @versions =
    map { s/\s+$//; $_ }
    /^Handle \s+ \w+ \s+  # Handle # 
    DMI \s type \s 4      # We're only interested in DMI type 4
    .*?                   # and let's skip things we don't care about
    \s+ Version: \s       # now we're near the good stuff
    ([^\n]+)              # our version
    /gsmx;

    my $cpuinfo = read_file('/proc/cpuinfo');
    my @names = $cpuinfo =~ m/model name\s*: (.*)/g;
    my %cpus;
    for (@versions) {
        next if /^0+$/;
        next if /^\s*$/;
        $cpus{$names[0]}++;
    }

    return \%cpus;
}

sub mem_info {
        open my $mem, "<", "/proc/meminfo" or die "meminfo: $!";
        my $ret;
        while (<$mem>) {
                if (/^MemTotal:\s+(\d+)/) {
                        $ret = $1;
                        last;
                }
        }
        die "MemTotal not found in /proc/meminfo" unless defined $ret;
        return floor( ($ret / 10 ** 6) + 0.5 );
}

sub get_tw_controllers {
    local $_;
    $_ = `tw_cli info` or do {
        print "DEBUG: Can't execute tw_cli info: $!\n";
        return;
    };
    my @result = /^Controller (\d+):/mg;
    unless (@result) {
        @result = /^c(\d+)/mg;
    }
    unless (@result) {
        print "DEBUG: Can't parse tw_cli output: $_\n";
        return;
    };
    return @result;
}

sub get_tw_ports {
    my $controller = shift;
    my %ports;
    local $_;
    $_ = `tw_cli info c$controller`;

    while (/^\s*Port\s+(\d+):[^(]+\((\d+) blocks/gm) {
        # convert size from blocks to bytes
        $ports{$1} = { size => $2 * 512 };
    }
    # try newer tw_cli output
    unless (%ports) {
        while (/^p(\d+)\s+\w+\s+u\d+\s+[\d.]+\s\w+\s+(\d+)/gm) {
            $ports{$1} = { size => $2 * 512 };
        }
    }

    return \%ports;
}

sub dsk_info {
        my %ret;
        if (-d "/proc/scsi/3w-xxxx") {
                my %drives;
                my @controllers = get_tw_controllers();
                foreach my $c (@controllers) {
                        my $ports = get_tw_ports($c);
                        while (my ($port, $info) = each(%$ports)) {
				my $size = floor( ($info->{size} / 10 ** 9) + 0.5 );
                                $drives{$size}++;
                        }
                }
                $ret{'3w-xxxx'} =  \%drives;
        # We assume 3ware and other disks aren't mixed.
        } else {
                open my $sfdisk, "sfdisk -s|" or die "sfdisk: $!";
                my %drives;
                while (<$sfdisk>) {
                        next if /^total/i;
                        die "unknown sfdisk output, possible huge devices?"
				unless m!/dev/[^:]+:\s*(\d+)!;
			my $size = floor( ($1 / 10 ** 6) + 0.5 );
                        $drives{$size}++;
                }
                close $sfdisk;

                if (-d "/proc/scsi/aic79xx") { $ret{aic79xx} = \%drives }
			else { $ret{ata} = \%drives }
        }
        return \%ret;
}

sub nic_info {
        # Add pciid => chipset map here
        # will match /^key/, complete ID not required
        my %pciids = (
                '8086:1229' => 'e100',
                '8086:100' => 'e1000',
                '8086:101' => 'e1000',
                '14e4:16' => 'bcm5700',
        );
        open my $pci, "lspci -n|" or die "lspci: $!";
        my %nics;
        while (<$pci>) {
                next unless my ($card) = /^\S+ Class 0200: ([\d\w]+:[\d\w]+)/;
                my $chipset = "Unknown. Please add me";
                foreach my $id (keys %pciids) {
                        if ($card =~ /^$id/) {
                                $chipset = $pciids{$id};
                                last;
                        }
                }
                $nics{$chipset}++;
        }
        return \%nics;
}

# return an IBM serial number if we find it, 0 otherwise
sub ibm_info {
	my $offset = 983040;
	my $seeklimit = 1024 * 1024;
	open my $mem, "/dev/mem" or die "/dev/mem: $!";
	seek $mem, $offset, 0;
	read $mem, my $data, $seeklimit - $offset;
	close $mem;
	if ($data =~ /eserver xSeries \d\d\d -\[([^]]+)\]-\0([^\0]+)/o) {
		return $2;
	} else {
		return 0;
	}
}

sub handle_nodeinfo {
    print YAML::Dump({	CPU => cpu_info(),
                        RAM => mem_info(),
                        DSK => dsk_info(),
                        NIC => nic_info(),
			SCSI => disk_model_info(),
			IBM => ibm_info(),
		     });
}

sub handle_zapbabel {
       # Currently the same as handle_babel("megazap")
       # But defining as a separate command for ease of remembering/use
       # We can backfill this later separately from megazap if desired.
       # - norby (4/14/4)
       handle_babel("megazap");
}

sub handle_babel {
    my $arg = shift;
    die "ERROR: need start or stop argument for babel.\n" unless $arg;
    return unless $arg =~ /^(start|test|stop|megazap)$/i;

    if ($arg eq "megazap") {
       handle_babel("stop");
       handle_babel("start");
       return;
    }

    unless (-x "/etc/init.d/babel") {
        print "no init found\n";
        return;
    }
    
    my $autostart = "/local/babelfish/.autostart-babel";
    if ($arg eq 'start' || $arg eq 'test') {
        open AUTOSTART, ">$autostart" or 
            die "ERROR: couldn't touch $autostart: $!\n";
        close AUTOSTART;
        invoke_cmd("/etc/init.d/babel", "start");
        if ($arg eq 'test') {
            unlink $autostart or die "ERROR: couldn't remove $autostart: $!\n";
        }
    } elsif ($arg eq 'stop') {
        invoke_cmd("/etc/init.d/babel", "stop");
    #} elsif ($arg eq 'zap') {
    #    handle_zapbabel();
    }
}

sub handle_refresh_gemstone {
    unless (-d "/usr/local/gemclient") {
        print "ERROR: Not a gemclient host\n";
        return;
    } 

    system("touch /usr/local/gemclient/.gem_refresh_now; svc -t /service/gemclient");
    print "OK\n";
}

sub handle_rc {
    my ($command,@args) = @_;
    my @allow = qw( echLzServer echPgServer );
    my %allow = map { $_=>1 } @allow;

    unless (defined $allow{$command}) {
        print "ERROR: Not a permitted command for handle_rc\n";
        return;
    }
    unless (-x "/etc/init.d/$command") {
        print "ERROR: missing /etc/init.d/$command\n";
        return;
    }
    system($command,@args);
    print "OK\n";
}

# arguments expected P4CLIENT, optional URL starting with //depot/
sub handle_p4sync {
    my ($p4client, $p4url) = @_;
    my ($user, $hostname);

    die ("Usage: p4sync P4CLIENT, <P4URL>\n")
        unless ($p4client);
    die ("Illegal client '$p4client'\n")
        unless (($user, $hostname) = 
                ($p4client =~ /^([[:alnum:]]+)(?:\.([[:alnum:]]+))?$/));
    die ("Illegal P4 URL '$p4url'\n")
        if ($p4url and $p4url !~ m|^//depot/|);
    
    unless ($hostname) {
        chomp ($hostname = `hostname`);
        $p4client .= ".$hostname";
    }

    print "Becoming $user\n";
    be_somebody ($user);
    my $ret = `P4CLIENT=$p4client /usr/local/bin/p4 client -o`;
    die ("Client $p4client maps //depot/..., will not sync that\n")
        if ($ret =~ m|^\s*//depot/\.\.\.\s+|m);

    my $cmd = "env P4CLIENT=$p4client /usr/local/bin/p4 sync";
    $cmd .= " $p4url" if ($p4url);
    invoke_cmd(split (' ', $cmd));
}

sub handle_gemok {
    my ($ok, $msg) = gem_ok();
    print $ok ? "OK" : "ERR";
    print ": $msg\n";
}

sub gem_ok {
    my ($diff, $date);
    my $gemstone = "";
    my $now = time;
    open my $fh, "</etc/motd" or return (0, "/etc/motd: $!");
    while (<$fh>) {
        next unless /gemstone:/;
        chomp;
        if (/^gemstone: (.*)$/) {
            $gemstone = $1;
            if ($gemstone =~ /BROKE: (.*)/) {
                $gemstone = $1;
                $gemstone =~ s/^ERROR: //;
            }
            next;
        } elsif (/^last-working-gemstone: (\d+) (.*)$/) {
            my $secs = $1;
            $date = $2;
            $diff = $now - $secs;
        }
    }
    close $fh;
    if (defined $diff) {
            if ($diff > (3600 * 3)) {
                return (0, "OLD: Last successful run: $date ($gemstone)");
            } else {
                return (1, "RECENT: ($date) ($gemstone)");
            }
    } else {
        return (0, "$gemstone");
    }
}


sub handle_maint2 {
    local $_;
    my @valid_args;
    my ($cmd,@args) = @_;
    if ($cmd =~ m/^[a-z]/) {
      
      my $i = system("/usr/local/manateed/maint/$cmd",@args);
      if ($? == -1) {
         print "MAINT: FAILED $cmd : $!\n";
      } elsif ($? & 127) {
         my $s = ($? & 127);
         print "MAINT: FAILED $cmd : signal $s\n";
      } elsif ($?)  {
         my $s = ($? >> 8);
         print "MAINT: FAILED $cmd : exit code $s\n";
      } else { 
         print "MAINT: SUCCESS $cmd\n";
      }
    } else {
      print "MAINT: FAILED $cmd : bad command\n";
    }
}

sub do_smartctl_3w {
    my ($c, $l, $p) = @_;

    local $_ = `smartctl -Hi -d 3ware,$p /dev/tw$l$c`;
    my ($dev, $serial, $firmware, $cap, $ata_version, $ata_std, $support,
        $enabled, $overall)
      = /Device \s Model: \s+ ([^\n]+) \n
    Serial \s Number: \s+ (\w+) \n
    Firmware \s Version: \s+ (\w+) \n
    User \s Capacity: \s+ ([\d,]+) \s bytes \n
    Device.* \n
    ATA \s Version \s is: \s+ (\d+) \n
    ATA \s Standard \s is: \s+ ([^\n]+) \n
    Local \s Time \s is: [^\n]+ \n
    SMART \s support \s is: \s+ ([^\n]+) \n
    SMART \s support \s is: \s+ ([^\n]+)
    .* 
    SMART \s overall-health [^:]+ : \s (\w+)/msx or die;

    $cap =~ s/,//g;

    my %res = (
        'device_model'     => $dev,
        'serial_number'    => $serial,
        'firmware_version' => $firmware,
        'capacity'         => $cap,
        'ata_version'      => $ata_version,
        'ata_standard'     => $ata_std,
        'smart_support'    => $support,
        'smart_enabled'    => $enabled eq "Enabled",
        'overall_health'   => $overall,
    );

    return \%res;
}

sub handle_smartctl_3w {
    my @controllers = get_tw_controllers();
    my %result;
    for my $c (@controllers) {
        my $info = `tw_cli info`;
        my $l;
        if ($info =~ /^c$c\s+[678]/m) {
            $l = "e";
        }
        else {
            $l = "a";
        }

        my $ports = get_tw_ports($c);
        my @ports = sort keys %$ports;
        for my $port (@ports) {
            $result{"c$c"}{"p$port"} = do_smartctl_3w($c, $l, $port);
        }
    }
    print YAML::Dump(\%result);
}

sub handle_hpacucli {

# Check if hp array controller exists
    my $found=0;
    open my $pci, "lspci -n|" or die "lspci: $!";
    while(<$pci>){
       $found++ if (/\b0e11:(0046|b060|b178)\b/);
    }
    unless($found) {
       print "ERROR: no HP controller found\n";
       exit 1;
    }
    my $hpacucli='/usr/bin/hpacucli';
    die "ERROR: no hpacucli on this box\n" unless (-x $hpacucli);
    my @slots;
    my $cmd="nice -n 17 $hpacucli controller all show";
    open(CMD,"$cmd|") || die "ERROR:Unable to pipe $cmd:$!";
    my @output=<CMD>;
    close CMD;
    foreach my $line (@output) {
        #Smart Array 6i in Slot 0      ()
        if ($line =~ /^Smart Array.*Slot (\w+).*/) {
           push(@slots,$1);
        }
    }
    my $ok=1;
    foreach my $slot (@slots) {
       $cmd="nice -n 17 $hpacucli controller slot=$slot pd all show";
       open (CMD,"$cmd|") || die "ERROR:Unable to pipe $cmd:$!";
       my @output=<CMD>;
       close CMD;
       my $array;
       foreach (@output) {
          $array=$1 if(/array (\w+)/);
          if(/physicaldrive/) {
            die "$_ doesn't belong to any known array" unless(defined $array);
            if (/physicaldrive (\d+:\d+).*failed/i) {
                my $drive=$1;
                s/^\s+//;
                print "ERROR:$slot:$array:$drive failed\n";
                $ok=0;
            }
          }
      }
  }
print "OK\n" if($ok);
}

sub handle_test_mcast {
  $ENV{"PATH"} = "/bin:/usr/local/bin:/sbin:/usr/sbin:/usr/local/sbin:/home/seco/tools/bin";
  system "test-multicast -i `netstat -nr | grep ^0.0.0.0 | sed 's/.* //'` | cr --noi";
}

%handlers = (
    '3winfo' => \&handle_3winfo,
    '3winfo2' => \&handle_3winfo,
    proxyramusage => \&handle_proxyramusage,
    'readdir' => \&handle_readdir,
    ls => \&handle_ls,
    md5 => \&handle_md5,
    checkdf => \&handle_checkdf,
    checkfs => \&handle_checkfs,
    checkfs2 => \&handle_checkfs2,
    checkfserrors => \&handle_checkfserrors,
    checkscsi => \&handle_checkscsi,
    checkdisks => \&handle_checkdisks,
    restart_gige => \&handle_restart_gige,
    kidpd => \&handle_kidpd,
    killidpd => \&handle_kidpd,
    check => \&handle_check,
    checkcrawler => \&handle_checkcrawler,
    date => \&handle_date,
    db_fresh => \&handle_db_fresh,
    df => \&handle_df,
    findpanic => \&handle_findpanic,
    fixcore => \&handle_fixcore,
    comparedb => \&handle_comparedb,
    getMonitorStats => \&handle_getMonitorStats,
    getMonitorStatUpdate => \&handle_getMonitorStats,
    hostname => \&handle_hostname,
    iostat => \&handle_iostat,
    ip => \&handle_ip,
    kill => \&handle_kill,
    killp => \&handle_killp,
    mem => \&handle_mem,
    ps => \&handle_ps,
    psef => \&handle_psef,
    searcher => \&handle_searcher,
    thumb => \&handle_thumb,
    swap => \&handle_swap,
    tail => \&handle_tail,
    teebridge => \&handle_teebridge,
    uptime => \&handle_uptime,
    version => \&handle_version,
    vip => \&handle_vip,
    wait => \&handle_wait,
    sleep => \&handle_wait,
    lzpath => \&handle_lzpath,
    dbtypes => \&handle_dbtypes,
    adddbtype => \&handle_adddbtype,
    refreshfields => \&handle_refreshfields,
    netstatport => \&handle_netstatport,
    netstat => \&handle_netstat,
    ttcp => \&handle_ttcp,
    ping => \&handle_ping,
    lastvam => \&handle_lastvam,
    lastidpd => \&handle_lastidpd,
    ndcreload => \&handle_ndcreload,
    ndccheck => \&handle_ndccheck,
    help => \&handle_help,
    tagchk => \&handle_tagchk,
    ntpqrv => \&handle_ntpqrv,
    sesymlink => \&handle_sesymlink,
    perm => \&handle_perm,
    zapmws => \&handle_zapmws,
    zap => \&handle_zap,
    uname => \&handle_uname,
    watcher => \&handle_watcher,
    w4 => \&handle_w4,
    w4dt => \&handle_w4dt,
    ipcrmall => \&handle_ipcrmall,
    unixtime => \&handle_unixtime,
    timeoffset => \&handle_timeoffset,
    kernel => \&handle_kernel,
    phantom_label => \&handle_phantom_label,
    nodeinfo => \&handle_nodeinfo,
    babel => \&handle_babel,
    zapbabel => \&handle_zapbabel,
    readlink => \&handle_readlink,
    refresh_gemstone => \&handle_refresh_gemstone,
    rc => \&handle_rc,
    maint   => \&handle_maint,
    maint2   => \&handle_maint2,
    p4sync  => \&handle_p4sync,
    gemok => \&handle_gemok,
    dmesg => \&handle_dmesg,
    dmidecode => sub { system "dmidecode" }, 
    hpainfo => \&handle_hpacucli,
    smartctl_3w => \&handle_smartctl_3w,
    multicast => \&handle_test_mcast,
    "test-multicast" => \&handle_test_mcast,
    nobody => \&handle_nobody,
    dbversion => \&handle_dbversion,
    rebootlog => \&handle_rebootlog,
);

# main()
$ENV{PATH}="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin";
#*STDERR = *STDOUT;  # That only affects perl, not other apps!
close(STDERR); open(STDERR,">&STDOUT");

tie *SYSLOG, 'Tie::Syslog', 'daemon.notice', 'manateed', 'pid', 'unix';
chdir "/usr/local/manateed" or die "/usr/local/manateed: $!";

$_ = <>;
unless (defined $_) {
    log_msg("got no commands");
    exit 1;
}

$|++;
my $silent_commands = qr/^\s*(?:checkfs|lastvam|ntpqrv|uptime)\s*$/;

log_msg("got cmd {$_}") unless /$silent_commands/;
my @cmds = split /;/;
foreach (@cmds) {
    log_msg("running cmd {$_}") unless /$silent_commands/;
    $_ = trim $_;

    my ($sub, @args) = split;
    $sub =~ s/-/_/g;

    my $subref = $handlers{$sub};
    die "no such command\n" unless $subref;

    $subref->(@args);
}
untie *SYSLOG;

#
# kanliu added below
#

#
# invoke w4 scripts
#

sub handle_w4
{
    my %actions = map { $_ => 1 }
        ('status', 'start', 'stop', 'kill', 'reload', 'restart', 'sleep', 'unsleep');

    my $action = lc shift @_;

    unless ($actions{$action} && -x ($action = "/home/watcher/w4/bin/scripts/$action"))
    {   
        warn "handle_w4: no such action '$action'\n";
        return 0;
    }

    print `$action @_`;
}

#
# invoke w4dt scripts, to interface with a special instance of devtools w4
# as mechanism for "masterctl"
#

sub handle_w4dt
{
    my %actions = map { $_ => 1 }
        ('status', 'start', 'stop', 'kill', 'reload', 'restart', 'sleep', 'unsleep');

    my $action = lc shift @_;

    unless ($actions{$action} && -x ($action = "/home/watcher/w4dt/bin/scripts/$action"))
    {   
        warn "handle_w4dt: no such action '$action'\n";
        return 0;
    }

    print `$action @_`;
}

#
# invoke a command in manateed/nobody/ as 'nobody'
#

sub handle_nobody
{
    be_nobody() unless $>;

    my ($cmd, @args) = @_;
    
    if ($cmd !~ m/^[A-Za-z0-9]/)
    {
        print "nobody: FAILED $cmd : bad command\n";
        return 0;
    }        

    system("/usr/local/manateed/nobody/$cmd",@args);
    my $s;

    if ($? == -1) 
    {
        print "nobody: FAILED $cmd : $!\n";
        return 0;
    } 

    if ($s = $? & 127)
    {
        print "nobody: FAILED $cmd : signal $s\n";
        return 0;
    } 

    if ($?)  
    {         
        $s = $? >> 8;
        print "nobody: FAILED $cmd : exit code $s\n";
        return 0;
    } 

    return 1;
}

#
# end of kanliu's addition
#

# doesn't handle kkoptout/kkqss, but nobody cares about KingKong
sub handle_dbversion {
    my $db = shift;
    
    $db = "db-$db" unless ($db =~ /^db-/);
    $db = "/export/crawlspace/$db";
    
    die "dbversion: ERROR: $db doesn't exist\n"
        unless (-d $db);
    die "dbversion: ERROR: missing Current-database symlink in $db\n"
        unless (-l "$db/Current-database");
    print handle_nobody ("readlink", "$db/Current-database");
}

sub handle_rebootlog {

    my ($action, $node, $who, @message) = @_;
use constant {
    REBOOTLOGDIR => "/export/crawlspace/rebootlog",
};

my $hash;
my @log;

$who ||= "unknown";


if ($node =~  m/[^A-Za-z0-9\-\.]/) {
    print "ERROR: $node contains invalid characers\n";
    return;
}

if ( $node =~ /\./g ) {
    # will barf if someone names a machine "a.foo"
    $hash = substr( $node, pos($node) - 3, 2 );
} else {
    $hash = substr( $node, -2 );
}


if (! -d REBOOTLOGDIR) {
    mkdir REBOOTLOGDIR or die "Could not create " . REBOOTLOGDIR . "$!";
}

if (! -d REBOOTLOGDIR . "/$hash") {
     mkdir REBOOTLOGDIR . "/$hash"  or die "Could not create " . REBOOTLOGDIR . "/$hash : $!";

}

my $logfile = REBOOTLOGDIR . "/$hash/$node";

if (-f $logfile)  {
    open (LOG, "< $logfile") || die "Could not open $logfile: $!";
    @log = <LOG>;
    close LOG;
}

# limit log file to last 20 entries
while (scalar @log >= 20) {
   shift @log;
}

if ($action eq "write") {
    push @log, time . ":$who:$ENV{'TCPREMOTEIP'}:". join (" ", @message) . "\n";
    open (LOG, "> $logfile") || die "Could not open $logfile: $!";
    foreach (@log) { print LOG $_; }
    close LOG;

}
elsif ($action eq "read") {
    open (LOG, "< $logfile") || die "Could not open $logfile: $!";
    while (<LOG>) { print; }
    close LOG;

}
else { print "ERROR: unknown action\n";  return}


}
