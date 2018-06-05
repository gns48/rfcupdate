#! /usr/bin/perl -w

use Net::FTP;
use IO::Handle;
use Getopt::Long;
use strict;

## Configuration parameters

my $RFCDIR  = ".";
my $LOGFILE = "update-report.log";
my $ABSENTLIST = "absent.txt";
my ($FTPSERV, $FTPUSER, $FTPPASS, $FTPDIR) =
    ("ftp.rfc-editor.org", 'ftp', 'ftp', 'in-notes');

my ($COMMAND, $ERROR) = (undef, undef);

# Command line flags
my ($PRINTVER, $PRINTHELP) = (undef, undef);

# Static globals
my @EXTLIST = qw(txt ps pdf);

#my @INDEX_LIST = qw(rfc-index.txt
#                    bcp-index.txt
#                    fyi-index.txt
#                    rfc-index-latest.txt
#                    rfc-index.xml
#                    rfc-ref.txt.new
#                    rfcxx00.txt
#                    std-index.txt);

my @INDEX_LIST = qw(rfc-index.txt
                    bcp-index.txt
                    fyi-index.txt
                    rfc-index-latest.txt
                    rfc-ref.txt.new
                    rfcxx00.txt
                    std-index.txt);


my $NUMBERLEN=4;
my $RFCFMT = "%0".$NUMBERLEN."d";

my $USAGE = "Usage: rfcutil [option...] <command>
Options:
-r, --rfcdir <dir>      set local RFC hierarchy root
-s, --server <name>     set FTP server name
-u, --user <name>       set FTP user name
-p, --password <string> set FTP password
-d, --dir <dir>         set FTP directory
-l, --logfile <name>    logfile name (will be appended)
-a, --absent            absent RFCs list name
-h, --help              print usage summary (this text)
-v, --version           print version number

Commands:
getindex    get new RFC indexes
whatabsent  print absent files statistics
toss        toss downloaded files to appropriate directories
update      update locat RFC database
            (do getindex+whatabsent+download files+toss)
view [<num>]
            unpack and display RFC <num>\n";

my $EMAIL='gleb.semenov@gmail.com';
my $VNUM='2.1';
my $VERSION = "rfcutil v$VNUM (c) 2011-2015 Gleb N. Semenov, $EMAIL\n";

#
# Local utility
#

sub expand_number($) {
    return sprintf($RFCFMT, shift @_);
}

sub get_dirname($) {
    my $num = shift;
    my $dir = expand_number($num - $num % 100);
    return "rfc$dir";
}

sub get_fullname($$) {
    my ($num, $ext) = @_;
    my $dir = get_dirname($num);
    $num = expand_number($num);
    return "$dir/rfc$num.$ext";
}

sub open_logfile() {
    my $rep;
    open($rep, ">>$LOGFILE") || die "can not open update report: $!";
    return $rep;
}

sub log_record($$$$) {
    my ($rep, $command, $subcommand, $line) = @_;
    print $rep localtime().": $command";
    print $rep ": $subcommand" if(defined $subcommand);
    print $rep ": $line" if(defined $line);
    print $rep "\n";
}

sub max($$) {
    my ($a, $b) = @_;
    return $a > $b ? $a : $b;
}

#
# FTP staff
#

sub getFile($$$$) {
    my ($ftp, $fname, $rep, $cmd) = @_;
    my ($rsize, $lsize) = (0, 0);
    print "getting $fname...";
    $rsize = $ftp->size($fname);
    $lsize = (stat($fname))[7] if (-e $fname);
    if($rsize) {
        if($lsize != $rsize) {
            $ftp->get($fname, "$fname");
            log_record($rep, $cmd, "getfile", sprintf("%ld -> %ld %s", $lsize, $rsize, $fname));
            print " $lsize -> $rsize\n";
        }
        else {
            log_record($rep, $cmd, "getfile", sprintf("%s: same size", $fname));
            print "not needed\n";
        }
    }
    else {
        log_record($rep, $cmd, "getfile", sprintf("%s: not found", $fname));
        print "not found\n";
    }
}

sub setupFTP($$$$) {
    my ($s, $u, $p, $d) = @_;
    my $ftp = Net::FTP->new($s, Debug => 0, Passive => 1) || die "Cannot connect to $s: $@\n";
    $ftp->login($u, $p) || die "Can not login to $s as $u: $@\n";
    $ftp->cwd($d);
    $ftp->binary();
    return $ftp;
}

#
# Whatabsent command subroutines
#

my %rfc_index;

sub wa_parse_string($) {
    my $str = shift;
    my ($key, $val);
    $str =~ m/^(\d\d\d\d)/;
    $key = $1;
    if($str =~ m/\(Not online\)/) {
        $val = 'offline';
    }
    elsif($str =~ m/Not issued\./) {
        $val = 'notissued';
    }
    else {
        $val = 'online';
    }
    $rfc_index{$key} = $val;
    return $key;
}

sub wa_file_is_present($) {
    my $num = shift;
    my $ext;
    foreach $ext (@EXTLIST) {
        return "present" if(-e get_fullname($num, $ext).".gz");
    }
    return "absent";
}

sub wa_online_present($$$$) {
    # nothing to do
}

sub wa_online_absent($$$$) {
    my ($cmd, $logfd, $listfd, $num) = @_;
    log_record($logfd, $cmd, "online_absent", sprintf("ftp rfc$RFCFMT", $num));
    print $listfd "ftp rfc$num\n";
}

sub wa_offline_present($$$$) {
    my ($cmd, $logfd, $listfd, $num) = @_;
    log_record($logfd, $cmd, "offline_present", sprintf("of? rfc$RFCFMT", $num));
    print $listfd "of? rfc$num\n";
}

sub wa_offline_absent($$$$) {
    my ($cmd, $logfd, $listfd, $num) = @_;
    log_record($logfd, $cmd, "offline_absent", sprintf("ofl rfc$RFCFMT", $num));
    print $listfd "ofl rfc$num\n";
}

sub wa_notissued_present($$$$) {
    my ($cmd, $logfd, $listfd, $num) = @_;
    log_record($logfd, $cmd, "notissued_present", sprintf("ni? rfc$RFCFMT", $num));
    print $listfd "ni? rfc$num\n";
}

sub wa_notissued_absent($$$$) {
    my ($cmd, $logfd, $listfd, $num) = @_;
    my ($fd, $fn);
    $fn = "rfc$num/rfc$num.txt";
    open($fd, ">$fn") || die "Can not create $fn: $!\n";
    print $fd, "RFC $num was never issued.\n";
    close($fd);
    log_record($logfd, $cmd, "notissued", sprintf("n/i rfc$RFCFMT", $num));
}

sub wa_absent_present($$$$) {
    my ($cmd, $logfd, $listfd, $num) = @_;
    log_record($logfd, $cmd, "absent_present", sprintf("??? rfc$RFCFMT", $num));
    print $listfd "??? rfc$num\n";
}

sub wa_absent_absent($$$$) {
    my ($cmd, $logfd, $listfd, $num) = @_;
    print $listfd "    rfc$num\n";
}

my %file_action = (
    'online&present'    => \&wa_online_present,
    'online&absent'     => \&wa_online_absent,
    'offline&present'   => \&wa_offline_present,
    'offline&absent'    => \&wa_offline_absent,
    'notissued&present' => \&wa_notissued_present,
    'notissued&absent'  => \&wa_notissued_absent,
    'absent&present'    => \&wa_absent_present,
    'absent&absent'     => \&wa_absent_absent
    );

#
# cmd_update routines
#

sub upd_getfiles($$$) {
    my ($rep, $cmd, $subcmd) = @_;
    my @ftplist = grep(/^ftp /, `cat $ABSENTLIST`);
    if(scalar @ftplist > 0) {
        my ($fn, $ext);
        my $ftp = setupFTP($FTPSERV, $FTPUSER, $FTPPASS, $FTPDIR);
        foreach $fn (@ftplist) {
            chomp($fn);
            ($_, $fn) = split(/\s/, $fn);
            $fn =~ s/rfc0*/rfc/;
            foreach $ext (@EXTLIST) {
                getFile($ftp, "$fn.$ext", $rep, $cmd);
            }
        }
        $ftp->quit();
    }
}

#
# Command processors
#

sub cmd_getindex($$$) {
    my ($rep, $cmd, $subcmd) = @_;
    my $ftp = setupFTP($FTPSERV, $FTPUSER, $FTPPASS, $FTPDIR);
    foreach my $name (@INDEX_LIST) {
        getFile($ftp, $name, $rep, $cmd);
    }
    $ftp->quit();
}

sub cmd_newdirs($$$) {
    my ($rep, $cmd, $subcmd) = @_;
    my $fd;
    open($fd, "rfc-index-latest.txt") || die "Can not open rfc-latest.txt: $!\n";
    while(my $line = <$fd>) {
        if($line =~ m/^([0-9]+)/) {
            my $dn = get_dirname($1);
            if(! -d "$dn") {
                print "Creating the $dn directory\n";
                mkdir("$dn");
                log_record($rep, $cmd, "newdirs", sprintf("%s created", $dn));
            }
        }
    }
    close($fd);
}

sub cmd_whatabsent($$$) {
    my ($rep, $cmd, $subcmd) = @_;
    my ($line, $string, $i, $maxnum, $fd);

    ### parse index ###
    open($fd, "rfc-index.txt") || die "Can not open RFC index: $!\n";
    while($line = <$fd>) {
        last if($line =~ /^\d\d\d\d/);
    }
    chomp($line);
    $string = $line;
    $maxnum = 1;
    while($line = <$fd>) {
        chomp($line);
        if($line =~ m/^(\d\d\d\d)/) {
            $maxnum = max(wa_parse_string($string), $maxnum);
            $string = $line;
        }
        elsif($line =~ m/^\s+\S/) {
            $line =~ s/^\s+/ /;
            $string = $string.$line;
        }
    }
    $maxnum = max(wa_parse_string($string), $maxnum);
    close($fd);

    ### scan files ###
    open($fd, ">$ABSENTLIST") || die "Can not create $ABSENTLIST: $!\n";
    for($i = 1; ($i <= $maxnum) || (-d get_dirname($i)); $i++) {
        my ($val, $num, $p_flag);
        $num = expand_number($i);
        $p_flag = wa_file_is_present($num);
        $val = exists($rfc_index{$num}) ? $rfc_index{$num} : "absent";
        $file_action{$val.'&'.$p_flag}->($cmd, $rep, $fd, $num);
    }
    close($fd);
    print grep(/^ftp /, `cat $ABSENTLIST`);
}

sub cmd_update($$$) {
    my ($rep, $cmd, $subcmd) = @_;
    cmd_getindex($rep, $cmd, 'getindex');
    cmd_newdirs($rep, $cmd, 'newdirs');
    cmd_whatabsent($rep, $cmd, 'whatabsent');
    upd_getfiles($rep, $cmd, 'getfiles');
    cmd_toss($rep, $cmd, 'toss');
    cmd_whatabsent($rep, $cmd, 'whatabsent');
}

sub cmd_view($$$) {
    my ($rep, $cmd, $subcmd) = @_;
    print "$cmd: command still unsuported... :(\n";
}

sub cmd_toss($$$) {
    my ($rep, $cmd, $subcmd) = @_;
    my ($fn, $num, $fnn);
    my @tlist = grep(/rfc\d+\.[txt|ps|pdf]/, `ls -1`);
    foreach $fn (@tlist) {
        chomp($fn);
        my ($name, $ext) = split(/\./, $fn);
        $name =~ m/rfc(\d+)/;
        $fnn = get_fullname($1, $ext);
        rename($fn, $fnn);
        system("gzip -qf $fnn");
        log_record($rep, $cmd, "toss", sprintf("%s -> %s.gz", $fn, $fnn));
        print "$fn -> $fnn.gz\n";
    }
}

my %dispatch_table = ('getindex' => \&cmd_getindex,
                      'newdirs' => \&cmd_newdirs,
                      'whatabsent' => \&cmd_whatabsent,
                      'update' => \&cmd_update,
                      'view' => \&cmd_view,
                      'toss' => \&cmd_toss);

#
# Command line verificator & parser
#

my $call_count = 0;

sub parse_command($) {
    if($call_count == 0) {
        $COMMAND = shift;
        $call_count++;
    }
    elsif($call_count == 1) {
        if($COMMAND eq 'view') {
            $call_count++;
        }
        else {
            $ERROR = 1;
            $call_count++;
        }
    }
    else {
        $ERROR = 1;
    }
}

sub verify_command($) {
    my $cmd = shift;
    return (defined $cmd) && (exists $dispatch_table{$cmd});
}

#
# Main routine
#
my $result = GetOptions("rfcdir=s" => \$RFCDIR,
                        "server=s" => \$FTPSERV,
                        "user=s" => \$FTPUSER,
                        "password=s" => \$FTPPASS,
                        "dir=s" => \$FTPDIR,
                        "help" => \$PRINTHELP,
                        "version" => \$PRINTVER,
                        "logfile=s" => \$LOGFILE,
                        "absent=s" => \$ABSENTLIST,
                        '<>' => \&parse_command);

my $done = 0;

if(defined $PRINTVER) {
    print $VERSION;
    $done = 1;
}

if(defined $PRINTHELP) {
    print $USAGE;
    $done = 1;
}

exit(0) unless(!$done);

if(!$result || $ERROR || !verify_command($COMMAND)) {
    print "Bad command!\n";
    print $USAGE;
    exit 0;
}

STDOUT->autoflush(1);

my $rep = open_logfile();
$dispatch_table{$COMMAND}->($rep, $COMMAND, undef);
close($rep);


