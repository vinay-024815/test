#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);

binmode STDIN;
binmode STDOUT;
my $origin = shift // '';
my $expected = 'chrome-extension://micgojkeebpbmhlbepmiebomdokpbcdk/';

sub reply {
  my ($value) = @_;
  my $payload = encode_json($value);
  print pack('V', length($payload)), $payload;
}
sub read_exact {
  my ($count) = @_;
  my $data = '';
  while (length($data) < $count) {
    my $read = read(STDIN, my $part, $count - length($data));
    die 'incomplete message' unless $read;
    $data .= $part;
  }
  return $data;
}

eval {
  die 'unauthorized origin' unless $origin eq $expected;
  my $length = unpack('V', read_exact(4));
  die 'invalid message size' if $length < 1 || $length > 1024 * 1024;
  my $request = decode_json(read_exact($length));
  my $action = $request->{action} // '';
  die 'unsupported action' unless $action eq 'check' || $action eq 'install';
  my $root = "$ENV{HOME}/Library/Application Support/CredentialVault";
  my $updater = "$root/dependency.sh";
  die 'updater not installed' unless -f $updater;
  local $SIG{ALRM} = sub { die 'timeout' };
  alarm 180;
  open my $child, '-|', '/bin/bash', $updater, '--native-action', $action or die 'could not launch updater';
  local $/;
  my $output = <$child> // '';
  close $child;
  alarm 0;
  my $result = decode_json($output);
  reply($result);
  1;
} or do {
  alarm 0;
  my $error = $@ || 'native updater failed';
  $error =~ s/[\r\n]+/ /g;
  reply({ ok => JSON::PP::false, status => 'error', error => $error });
};
