#!/usr/bin/env python
# Copyright (C) 2007-2008 Matthew West
# Licensed under the GNU General Public License version 2 or (at your
# option) any later version. See the file COPYING for details.

import os, sys, math
import copy as module_copy
from Scientific.IO.NetCDF import *
from pyx import *
sys.path.append("../tool")
from pmc_data_nc import *
from pmc_pyx import *
import numpy

graph_width = 8
v_space = 0.5

f = NetCDFFile("out/urban_plume_0.5_3am_state_0001_00000241.nc")
particles = read_particles(f)
x_axis = pmc_log_axis(min = 1e-2, max = 2, n_bin = 160)
y_axis = pmc_linear_axis(min = 0, max = 100, n_bin = 100)
dry_bin_array = numpy.zeros([x_axis.n_bin, y_axis.n_bin])
wet_bin_array = numpy.zeros([x_axis.n_bin, y_axis.n_bin])
for particle in particles:
    diameter = 2.0 * particle.radius() * 1e6 # um
    comp_frac = particle.mass(include = ["BC"]) \
                / particle.mass(exclude = ["H2O"]) * 100
    x_bin = x_axis.find(diameter)
    y_bin = y_axis.find(comp_frac)
    if particle.mass(include = ["H2O"]) == 0.0:
        dry_bin_array[x_bin, y_bin] = 1.0
    else:
        wet_bin_array[x_bin, y_bin] = particle.mass(include = ["H2O"]) \
                                      / particle.mass()
max_wet = wet_bin_array.max()
wet_bin_array = wet_bin_array / max_wet

c = canvas.canvas()

g2 = c.insert(graph.graphxy(
    width = graph_width,
    x = graph.axis.log(min = x_axis.min,
                       max = x_axis.max,
                       title = r'diameter ($\mu$m)'),
    y = graph.axis.linear(min = y_axis.min,
                          max = y_axis.max,
                          title = r"$f_{\rm BC,all}$",
                          texter = graph.axis.texter.decimal(suffix = r"\%"))))
g1 = c.insert(graph.graphxy(
    width = graph_width,
    ypos = g2.height + v_space,
    x = graph.axis.linkedaxis(g2.axes["x"]),
    y = graph.axis.linear(min = y_axis.min,
                          max = y_axis.max,
                          title = r"$f_{\rm BC,all}$",
                          texter = graph.axis.texter.decimal(suffix = r"\%"))))

dry_plot_data = pmc_histogram_2d(dry_bin_array, x_axis, y_axis)
if len(dry_plot_data) > 0:
    g1.plot(graph.data.points(dry_plot_data,
                              xmin = 1, xmax = 2, ymin = 3, ymax = 4, color = 5),
            styles = [graph.style.rect(rainbow_palette)])
wet_plot_data = pmc_histogram_2d(wet_bin_array, x_axis, y_axis)
if len(wet_plot_data) > 0:
    g2.plot(graph.data.points(wet_plot_data,
                              xmin = 1, xmax = 2, ymin = 3, ymax = 4, color = 5),
            styles = [graph.style.rect(rainbow_palette)])
add_color_bar(g2, min = 0.0, max = max_wet * 100,
              title = r"water fraction", palette = rainbow_palette,
              bar_x_offset = 0.8,
              texter = graph.axis.texter.decimal(suffix = r"\%"))

boxed_text(g1, 0.8, 0.9, "dry")
boxed_text(g2, 0.8, 0.9, "wet")

c.writePDFfile("out/comp_2d_all_water_4.pdf")
