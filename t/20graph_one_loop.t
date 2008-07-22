#!/usr/bin/perl

require 5;
use strict;
use lib qw(t);

require 'regress-p4-graph.pl';

regress('//depot/site/main/mabel/service/build.xml#2');

__END__
* [shaslam] //depot/site/main/mabel/service/build.xml #2 integrate@90398 Update cancellation engine to
|\
| * [shaslam] //depot/site/branch/2005-09-15/canxengine-hibernate/mabel/service/build.xml #4 edit@90396 Actually build hibernate class
| * [shaslam] //depot/site/branch/2005-09-15/canxengine-hibernate/mabel/service/build.xml #3 edit@90395 Include classes from build/cli
| * [shaslam] //depot/site/branch/2005-09-15/canxengine-hibernate/mabel/service/build.xml #2 edit@90394 Finally sort out build system
| * [shaslam] //depot/site/branch/2005-09-15/canxengine-hibernate/mabel/service/build.xml #1 add@90392 Pull in more things from mainl
|/
* [shaslam] //depot/site/main/mabel/service/build.xml #1 branch@86233 Integrate new Mabel Service AP
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #17 edit@84558 Implement marking items as hav
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #16 edit@83173 Add test class for testing RMI
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #15 edit@82672 "ant -Dproject=mabel dist" now
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #14 edit@82656 Update cancellation engine bui
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #13 edit@82645 Replace RMI wrapper service
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #12 edit@82560 Put cancellation engine result
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #11 edit@82009 Add generic dump-schema target
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #10 edit@81926 Extract as much as possible fr
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #9 edit@81460 Call CanxEngine to get purchas
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #8 edit@81024 Test using Zeroconf to contact
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #7 edit@80815 Scrap "client" and "data" subp
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #6 edit@80396 Rename MabelService to McdbSer
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #5 edit@80232 Adding support for wrapping up
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #4 edit@80177 Add Perl script for extracting
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #3 edit@79463 Handle a couple of Fields in f
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #2 edit@79461 Expand unit test framework to
* [shaslam] //depot/site/branch/2005-04-13/mabel-shaslam/mabel/service/build.xml #1 add@79457 Som initial Mabel Service API
