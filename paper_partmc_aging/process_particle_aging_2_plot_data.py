#!/usr/bin/env python
# Copyright (C) 2007-2009 Nicole Riemer and Matthew West
# Licensed under the GNU General Public License version 2 or (at your
# option) any later version. See the file COPYING for details.

import os, sys
import copy as module_copy
from Scientific.IO.NetCDF import *
sys.path.append("../tool")
from pmc_data_nc import *
from fig_helper import *
from numpy import *

const = load_constants("../src/constants.f90")

bin = level_mid + 1

for coag in [True, False]:
    if coag:
        coag_suffix = "wc"
    else:
        coag_suffix = "nc"






    time_emitted = {}
    time_entered_bins = [{} for i in range(n_level_bin + 2)]

    first_time = True
    for [time, filename, key] in time_filename_list:
        #DEBUG
        #if time > 121:
        #    sys.exit(0)
        #DEBUG
        print time, filename
        ncf = NetCDFFile(filename)
        particles = aero_particle_array_t(ncf)
        particles.id = [int(i) for i in particles.id]
        env_state = env_state_t(ncf)
        ncf.close()
        num_den = 1.0 / array(particles.comp_vol)
        total_num_den = num_den.sum()
        soot_mass = particles.mass(include = ["BC"])
        critical_ss = particles.kappa_rh(env_state, const) - 1.0
        ss_bin = ss_active_axis.find_clipped_outer(critical_ss)
        id_set = set([particles.id[i] for i in range(particles.n_particles)])
        particle_index_by_id = dict([[particles.id[i], i] for i in range(particles.n_particles)])

        for i in range(particles.n_particles):
            id = particles.id[i]
            if id not in time_emitted:
                time_emitted[id] = time
            bin = ss_bin[i]
            if id not in time_entered_bins[bin]:
                time_entered_bins[bin][id] = time

    max_id = max(time_emitted.keys())

    filename = os.path.join(aging_data_dir,
                            "particle_aging_%s_%%s.txt" % coag_suffix)

    time_emitted_array = zeros(max_id)
    time_emitted_array = -1.0
    for (id, time) in time_emitted.iteritems():
        time_emitted_array[id] = time
    savetxt(filename % "time_emitted", time_emitted_array)

    for bin in range(n_level_bin + 2):
        print "bin", bin
        filename_bin = filename % ("%08d_%%s" % bin)

        time_entered_bins_array = zeros(max_id)
        time_aging_array = zeros(max_id)

        time_entered_bins_array = -1.0
        time_aging_array = -1.0

        for (id, time) in time_entered_bins[bin]:
            time_entered_bins_array[id] = time
            if time_emitted_array[id] < 0.0:
                raise Exception("ID %d entered bin %d at time %f but was never emitted" % id, bin, time)
            time_aging_array[id] = time - time_emitted_array[id]

        savetxt(filename_bin % "time_entered_bins", time_entered_bins_array)
        savetxt(filename_bin % "time_aging", time_aging_array)