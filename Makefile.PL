use ExtUtils::MakeMaker;
use File::Spec;

my $file = File::Spec->catfile(File::Spec->curdir, 'lib', 'Queue.pm');

WriteMakefile(
    'NAME' => 'Queue',
    'VERSION_FROM' => $file,
    'EXE_FILES' => [
        'ocsqueue',
        'ocsqmon',
    ],
    'PREREQ_PM' => {
        'Test::More' => 0,
        'DRAMA' => 0,
        'Jit' => 1.18,
    },
    'dist' => {
        COMPRESS => 'gzip -9f',
    },
    ABSTRACT_FROM => $file,
    AUTHOR => 'Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>',
);
