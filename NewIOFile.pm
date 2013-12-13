package NewIOFile;

use base qw(IO::File);

sub print {
    my $class=shift;
    my $arg=shift;

    my $date=scalar(localtime);
    my $uid=(getpwuid($<))[0];
    $arg=~s/^\x0d$//g;
    $arg=~s/\x0d\x0a/\n/g;
    $arg=~s/\n/\n$date $$\t$uid\t/msg;
    $class->SUPER::print($arg);
}

1;
