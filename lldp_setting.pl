#!/usr/bin/perl

use FindBin qw($Bin);
use lib "$Bin";

use strict;
use SCM;
use Storable qw(dclone);
use Data::Compare;
use POSIX ":sys_wait_h";
use Socket;
use Fcntl qw (:DEFAULT :flock);
use Config::General;
use Getopt::Std;

use constant TAGGED_PORT => 0;
use constant UNTAGGED_PORT => 1;

my %options=&read_options();

my $lldp_setting_config = Config::General->new('lldp_setting.conf');
my %lldp_setting_config=$lldp_setting_config->getall;

my $fork_number=$lldp_setting_config{'fork'}->{'fork_number'};
my $log_file=$lldp_setting_config{'log'}->{'log_file'};
my $debug_flag=$lldp_setting_config{'debug'}->{'debug_enable'};
my %users=%{$lldp_setting_config{'users'}->{'user'}};

my @switch_ip=net_to_host_array($options{'switch_ip'});

my %pids;

foreach my $switch_ip (@switch_ip){

    my $pid = fork();
    if ($pid){
	$pids{$pid}=1;
    }else{
	my @connect_type=('ssh','telnet');
    
	my $scm;
    
	foreach my $connect_type (@connect_type){
	    foreach my $user_name (keys %users){
		(my $error, $scm)=SCM->connect({
		    'connect_type'	=> $connect_type,
		    'switch_ip'		=> $switch_ip,
		    'username'		=> $user_name,
		    'password'		=> $users{$user_name}->{'password'},
		    'log_file'		=> \&PrintLog,
		    'debug_enable'	=> $debug_flag
		});
		last if ($error==1 or defined $scm);
	    }
	    last if (defined $scm);
	}

	if (defined $scm){
	    my $error;
	    
	    ($error, my %vlan_data_current)=$scm->get_vlan_setting();
	    &PrintLog("ERROR: $switch_ip get_vlan_setting() $error") && exit if (defined $error);
	    
	    ($error, my %switch_info)=$scm->get_switch_info();
	    &PrintLog("ERROR: $switch_ip get_switch_info() $error") && exit if (defined $error);

	    my $mgmt_vlan;
	    foreach my $vlan_id (keys %vlan_data_current){
		if ($vlan_data_current{$vlan_id}->{'name'} eq $switch_info{'mgmt_vlan_name'}){
		    $mgmt_vlan=$vlan_id;
		    last;
		}
	    }
	    &PrintLog("ERROR: $switch_ip can't find mgmt vlan $switch_info{'mgmt_vlan_name'}") && exit unless (defined $mgmt_vlan);

	    my @ports_for_lldp;
	    unless ($options{'all_port_flag'}){
		@ports_for_lldp=keys %{$vlan_data_current{$mgmt_vlan}->{'ports'}}
	    }else{
		($error, my %ports_all)=$scm->get_all_ports();
		&PrintLog("ERROR: $switch_ip get_all_ports() $error") && exit if (defined $error);
		@ports_for_lldp=keys %ports_all;
	    }

	    my %vlan_data_new=&check_vlan_setting(\@ports_for_lldp, \%vlan_data_current);

	    unless (Compare(\%vlan_data_current,\%vlan_data_new)){
		($error, my %vlan_data_after_setting)=$scm->set_vlan_setting(%vlan_data_new);
		&PrintLog("ERROR: $switch_ip vlans not setting up") && exit unless(Compare(\%vlan_data_after_setting,\%vlan_data_new));
	    }

	    $error=$scm->set_lldp_setting(@ports_for_lldp);
	    &PrintLog("ERROR: $switch_ip set_lldp_setting() $error") && exit if (defined $error);
	    
	    $error=$scm->send_config_cmd(60,"save");
	    &PrintLog("ERROR: $switch_ip $error") && exit if (defined $error);
	}else{
	    &PrintLog("ERROR: $switch_ip Can't connect to switch") && exit;
	}
	&PrintLog("OK: $switch_ip lldp setting up") && exit;
    }

    while (scalar(keys %pids) >= $fork_number){
	foreach my $pid (keys %pids){
	    my $kid = waitpid($pid, WNOHANG);
	    if ($kid>0){
		delete ($pids{$pid});
	    }
	}
	sleep 1;
    }
}

while (%pids){
    foreach my $pid (keys %pids){
	my $kid = waitpid($pid, WNOHANG);
	if ($kid>0){
	    delete ($pids{$pid});
	}
    }
    sleep 1;
}

sub check_vlan_setting {
    my @ports=@{(shift)};
    my %vlan_data_new=%{(dclone(shift))};

    foreach my $port (@ports){
	$vlan_data_new{1}->{'ports'}->{$port}=TAGGED_PORT unless (exists $vlan_data_new{1}->{'ports'}->{$port});
    }

    return %vlan_data_new;
}

sub net_to_host_array {
    my $ip=shift;

    my ($ip_address,$netmask)=split("/",$ip);

    return $ip_address if ($netmask eq '' or $netmask==32);

    my $ip_address_binary = inet_aton( $ip_address );
    my $netmask_binary = ~pack("N", (2**(32-$netmask))-1);
    my $first_valid= unpack('N', $ip_address_binary & $netmask_binary )+1;
    my $last_valid= unpack('N', $ip_address_binary | ~$netmask_binary )-1;

    return map {inet_ntoa( pack 'N', $_ )} ($first_valid..$last_valid);
}

sub PrintLog {
    my $text=shift;
    sysopen(LOG_FILE,$log_file,O_APPEND | O_WRONLY | O_CREAT) or return 1;
    flock (LOG_FILE, LOCK_EX);
    my $date=scalar localtime;
    $text=~s/[\x0a\x0d]+/\n/g;
    foreach my $line (split ("\n", $text)){
	print LOG_FILE "$date\t$$\t$line\n";
    }
    close LOG_FILE;
    return 1;
}

sub read_options {
    my %options=();
    my %return_options;
    getopts("s:a", \%options);
    if (exists $options{'s'}){
        unless ($options{'s'}=~m/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(?:\/(?:\d|1\d|2\d|3[0-2]))?$/){
            &help();
            exit;
	}else{
    	    $return_options{'switch_ip'}=$options{'s'};
    	    $return_options{'all_port_flag'}=1 if exists ($options{'a'});
	}
    }else{
	&help();
        exit;
    }
    return %return_options;
}

sub help {
    print "Usage :\t$0 -s switch_ip[/net_mask] [-a]\n";
}