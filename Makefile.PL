use ExtUtils::MakeMaker;
use File::Spec;

my $file = File::Spec->catfile(File::Spec->curdir, "lib", "Queue.pm");

WriteMakefile( 
               'NAME'           => 'Queue',
               'VERSION_FROM'   => $file,
	       'EXE_FILES'      => [  'qmon' ],
               'PREREQ_PM'      => { 
                                    'Test::More' => 0,
                                   },
               'dist'           => { COMPRESS => "gzip -9f"},
               ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
               ( ABSTRACT_FROM  => $file,
                 AUTHOR         => 'Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>') : ()),
             );
