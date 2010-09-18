package Queue::Backend::FailureReason;

=head1 NAME

Queue::Backend::FailureReason - Why did an entry fail to prepare?

=head1 SYNOPSIS

  use Queue::Backend::FailureReason;

  $r = new Queue::Backend::FailureReason("MissingTarget");

  $reason_string = $

=head1 DESCRIPTION

This object keeps track of all the reasons why something failed
in sending a queue entry to the backend. Used to group information
together rather than passing it around as a raw hash.

=cut

use 5.006;
use warnings;
use strict;
use Carp;

=head1 METHODS

The following methods are provided:

=head2 Constructors

=over 4

=item B<new>

Constructor. Takes a single argument specifying the type of the
failure and a hash with any particular information as to how to fix
the problem. Supported types are shown in the documentation for the
C<type> method.

The first argument is required.

  $r = new Queue::Backend::FailureReason( "MissingTarget" );

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  # look at the arguments
  my $type = shift;
  croak "Must provide a type to constructor"
    unless $type;

  my $r = {
	   Type => undef,
	   Details => {@_},
	  };

  bless $r, $class;

  $r->type( $type );

  return $r;
}

=back

=head2 Accessors

=over 4

=item B<type>

Type of failure. Currently supports:

  MissingTarget  - entry did not have a target
  NeedNextTarget - entry needs following target

=cut

sub type {
  my $self = shift;
  if (@_) {
    my $type = shift;
    if ($type ne 'MissingTarget' &&
        $type ne 'NeedNextTarget') {
      croak "Type [$type] is not recognized";
    }
    $self->{Type} = $type;
  }
  return $self->{Type};
}

=item B<index>

Index of the entry that has problems.

  $r->index( $curindex );

=cut

sub index {
  my $self = shift;
  if (@_) {
    $self->{Index} = shift;
  }
  return $self->{Index};
}


=item B<details>

Detailed data on how to fix the problem. For MissingTarget this
will hopefully include keys:

  AZ - reference AZ of related target
  EL - reference EL of related target
  MODE - observing mode
  FILTER - filter used for observations
  TIME   - time of failure in ISO date format
  ENTRY - Additional information from the entry (optional)
  FOLLOWING - whether the coordinate come from a following
    observation or a previous observation
  CAL - indicates that rather than knowing the coordinates
    of a related observation we know that it is meant to be
    a calibrator (this reduces the choices)

Returns hash reference in scalar context, hash in list context.
If a hash is provided as an argument, all content will be overwritten.

=cut

sub details {
  my $self = shift;
  if (@_) {
    %{ $self->{Details} } = @_;
  }
  if (wantarray) {
    return %{ $self->{Details} };
  } else {
    return $self->{Details};
  }
}

=back

=head1 NOTES

Different types of failures could have been represented by sub-classes
but this just just an alpha release proof-of-concept.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>.

=head1 COPYRIGHT

Copyright (C) 2002 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut

1;
