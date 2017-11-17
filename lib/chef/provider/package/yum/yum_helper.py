#!/usr/bin/env python3
# vim: tabstop=8 expandtab shiftwidth=4 softtabstop=4

import sys
import yum
import signal
import os
import json
import re
from rpmUtils.miscutils import stringToVersion,compareEVR
from rpmUtils.arch import getBaseArch, getArchList

base = None

def get_base():
    global base
    if base is None:
        base = yum.YumBase()
        base.preconf.debuglevel = -5
        base.preconf.errorlevel = -1
        base.preconf.plugins = True
    return base

def versioncompare(versions):
    arch_list = getArchList()
    candidate_arch1 = versions[0].split(".")[-1]
    candidate_arch2 = versions[1].split(".")[-1]

    # The first version number passed to this method is always a valid nevra (the current version)
    # If the second version number looks like it does not contain a valid arch
    # then we'll chop the arch component (assuming it *is* a valid one) from the first version string
    # so we're only comparing the evr portions.
    if (candidate_arch2 not in arch_list) and (candidate_arch1 in arch_list):
       final_version1 = versions[0].replace("." + candidate_arch1,"")
    else:
       final_version1 = versions[0]

    final_version2 = versions[1]

    (e1, v1, r1) = stringToVersion(final_version1)
    (e2, v2, r2) = stringToVersion(final_version2)

    evr_comparison = compareEVR((e1, v1, r1), (e2, v2, r2))
    outpipe.write('{0}\n'.format(evr_comparison))
    outpipe.flush()

def install_only_packages(name):
    base = get_base()
    if name in base.conf.installonlypkgs:
      outpipe.write('True')
    else:
      outpipe.write('False')
    outpipe.flush()

def query(command):
    base = get_base()

    enabled_repos = base.repos.listEnabled()

    # Handle any repocontrols passed in with our options
    if 'enablerepos' in command:
      base.repos.enableRepo(*command['enablerepos'])

    if 'disablerepos' in command:
      base.repos.disableRepo(*command['disablerepos'])

    args = { 'name': command['provides'] }
    do_nevra = False
    if 'epoch' in command:
        args['epoch'] = command['epoch']
        do_nevra = True
    if 'version' in command:
        args['ver'] = command['version']
        do_nevra = True
    if 'release' in command:
        args['rel'] = command['release']
        do_nevra = True
    if 'arch' in command:
        desired_arch = command['arch']
        args['arch'] = command['arch']
        do_nevra = True
    else:
        desired_arch = getBaseArch()

    obj = None
    if command['action'] == "whatinstalled":
        obj = base.rpmdb
    else:
        obj = base.pkgSack

    # if we are given "name == 1.2.3" then we must use the getProvides() API.
    #   - this means that we ignore arch and version properties when given prco tuples as a package_name
    #   - in order to fix this, something would have to happen where getProvides was called first and
    #     then the result was searchNevra'd.  please be extremely careful if attempting to fix that
    #     since searchNevra does not support prco tuples.
    if any(elem in command['provides'] for elem in r"<=>"):
        # handles flags (<, >, =, etc) and versions, but no wildcareds 
        pkgs = obj.getProvides(*yum.misc.string_to_prco_tuple(command['provides']))
    elif do_nevra:
        # now if we're given version or arch properties explicitly, then we do a SearchNevra.
        #  - this means that wildcard version in the package_name with an arch property will not work correctly
        #  - again don't try to fix this just by pushing bugs around in the code, you would need to call
        #    returnPackages and searchProvides and then apply the Nevra filters to those results.
        pkgs = obj.searchNevra(**args)
        if (command['action'] == "whatinstalled") and (not pkgs):
          pkgs = obj.searchNevra(name=args['name'], arch=desired_arch)
    else:
        pats = [command['provides']]
        pkgs = obj.returnPackages(patterns=pats)

        if not pkgs:
            # handles wildcards
            pkgs = obj.searchProvides(command['provides'])

    if not pkgs:
        outpipe.write('{0} nil nil\n'.format(command['provides'].split().pop(0)))
        outpipe.flush()
    else:
        # make sure we picked the package with the highest version
        pkgs = base.bestPackagesFromList(pkgs,arch=desired_arch,single_name=True)
        pkg = pkgs.pop(0)
        outpipe.write('{0} {1}:{2}-{3} {4}\n'.format(pkg.name, pkg.epoch, pkg.version, pkg.release, pkg.arch))
        outpipe.flush()

    # Reset any repos we were passed in enablerepo/disablerepo to the original state in enabled_repos
    if 'enablerepos' in command:
        for repo in command['enablerepos']:
            if base.repos.getRepo(repo) not in enabled_repos:
                base.repos.disableRepo(repo)

    if 'disablerepos' in command:
        for repo in command['disablerepos']:
            if base.repos.getRepo(repo) in enabled_repos:
                base.repos.enableRepo(repo)

# the design of this helper is that it should try to be 'brittle' and fail hard and exit in order
# to keep process tables clean.  additional error handling should probably be added to the retry loop
# on the ruby side.
def exit_handler(signal, frame):
    sys.exit(0)

signal.signal(signal.SIGINT, exit_handler)
signal.signal(signal.SIGHUP, exit_handler)
signal.signal(signal.SIGPIPE, exit_handler)

if len(sys.argv) < 3:
  inpipe = sys.stdin
  outpipe = sys.stdout
else:
  inpipe = os.fdopen(int(sys.argv[1]), "r")
  outpipe = os.fdopen(int(sys.argv[2]), "w")

while 1:
    # kill self if we get orphaned (tragic)
    ppid = os.getppid()
    if ppid == 1:
        sys.exit(0)
    line = inpipe.readline()
    command = json.loads(line)
    if command['action'] == "whatinstalled":
        query(command)
    elif command['action'] == "whatavailable":
        query(command)
    elif command['action'] == "versioncompare":
        versioncompare(command['versions'])
    elif command['action'] == "installonlypkgs":
         install_only_packages(command['package'])
    else:
        raise RuntimeError("bad command")
