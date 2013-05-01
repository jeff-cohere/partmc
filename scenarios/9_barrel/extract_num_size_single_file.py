import sys
sys.path.append('../../tool/')
import partmc
import scipy.io
import os
import numpy
import math
import mpl_helper
import matplotlib.pyplot as plt

#file = "out_with_fractal/case_0001_wc_0001_00000001.nc"
#ncf = scipy.io.netcdf.netcdf_file(file, 'r')
#particles = partmc.aero_particle_array_t(ncf)
#env_state = partmc.env_state_t(ncf)
#ncf.close()

#dry_diameters = particles.dry_diameters()
#x_values = dry_diameters
#x_grid = partmc.log_grid(min=1e-8, max=1e-6, n_bin=100)

#dist = partmc.histogram_1d(x_values, x_grid, weighted=True, weights=particles.num_concs)

col = 15

partmc_num = numpy.loadtxt("out_0212/barrel_wc_nummass_source_0001_aero_size_num.txt")
ref_data = numpy.loadtxt("ref_0212/ref_aero_size_num_regrid.txt")
raw_counts = numpy.loadtxt("ref_0212/ref_aero_raw_counts_regrid.txt")

# Calculate raw count error
ref_data_err_ratio_counts = []
for i in raw_counts[:,col]:
    if (i == 0):
       ref_data_err_ratio_counts.append(0)
    else:
       ref_data_err_ratio_counts.append(1 / numpy.sqrt(i))

# Calculate size error
ref_data_err_ratio_size = []
for i in range(0,ref_data.shape[0]):
    if (i == 0 and ref_data[i,col]!=0):
       ref_data_err_ratio_size.append(0.05 * ref_data[i,0] * abs(ref_data[i+1,col] - ref_data[i,col]) \
            / (ref_data[i+1,0] - ref_data[i,0]) / ref_data[i,col])
    elif (i == ref_data.shape[0]-1 and ref_data[i,col]!=0):
       ref_data_err_ratio_size.append(0.05 * ref_data[i,0] * abs(ref_data[i,col] - ref_data[i-1,col]) \
            / (ref_data[i,0] - ref_data[i-1,0]) / ref_data[i,col])
    elif (i > 0 and i < ref_data.shape[0]-1 and ref_data[i,col]!=0):
       ref_data_err_ratio_size.append(0.05 * ref_data[i,0] * abs(ref_data[i+1,col] - ref_data[i-1,col]) \
            / (ref_data[i+1,0] - ref_data[i-1,0]) / ref_data[i,col])
    else:
       ref_data_err_ratio_size.append(0)

# Calculate flow rate error (constant of 1.5%)
ref_data_err_ratio_flow = [0.015]*ref_data.shape[0]

ratio_counts = numpy.array(ref_data_err_ratio_counts)
ratio_size = numpy.array(ref_data_err_ratio_size)
ratio_flow = numpy.array(ref_data_err_ratio_flow)

ref_data_err_ratio = numpy.sqrt(ratio_counts**2 + ratio_size**2 + ratio_flow**2)

ref_data_err = ref_data_err_ratio * ref_data[:,col]

# plot slope
slope = []
for i in range(0,ref_data.shape[0]):
    if (i == 0):
       slope.append((ref_data[i+1,col] - ref_data[i,col]) \
            / (ref_data[i+1,0] - ref_data[i,0]))
    elif (i == ref_data.shape[0]-1):
       slope.append((ref_data[i,col] - ref_data[i-1,col]) \
            / (ref_data[i,0] - ref_data[i-1,0]))
    else:
       slope.append((ref_data[i+1,col] - ref_data[i-1,col]) \
            / (ref_data[i+1,0] - ref_data[i-1,0]))
slope_array = numpy.array(slope)

(figure, axes) = mpl_helper.make_fig(colorbar=False)
axes.semilogx(partmc_num[:,0], slope_array, color='k')
axes.set_title("")
axes.set_xlabel("Dry diameter (m)")
axes.set_ylabel(r"Slope")
axes.grid()
filename_out = "slope.pdf"
figure.savefig(filename_out)

(figure, axes) = mpl_helper.make_fig(colorbar=False)
axes.semilogx(partmc_num[:,0], partmc_num[:,col]*math.log(10), color='k',linestyle='--')
axes.errorbar(ref_data[:,0],ref_data[:,col],yerr=ref_data_err,color='r')
axes.set_title("")
axes.set_xlabel("Dry diameter (m)")
axes.set_ylabel(r"Number concentration ($\mathrm{m}^{-3}$)")
axes.grid()
axes.set_ylim(0,0.1e12)
axes.legend(('PartMC','Barrel'))
filename_out = "aero_num_size.pdf"
figure.savefig(filename_out)

rho = 1760 # density in kgm-3
(figure, axes) = mpl_helper.make_fig(colorbar=False)
ref_data_err_mass = math.pi / 6. * rho * ref_data[:,0]**3 * ref_data_err
axes.semilogx(partmc_num[:,0], partmc_num[:,col] * math.pi / 6. * rho * partmc_num[:,0]**3 * math.log(10), color='k',linestyle='--')
axes.errorbar(ref_data[:,0],ref_data[:,col] * math.pi / 6. * rho * ref_data[:,0]**3,yerr=ref_data_err_mass,color='r')
axes.set_title("")
axes.set_xlabel("Dry diameter (m)")
axes.set_ylabel(r"Mass concentration (kg $\mathrm{m}^{-3}$)")
axes.grid()
axes.set_ylim(0,0.25e-5)
axes.ticklabel_format(style='sci', scilimits=(0,0), axis='y')
axes.legend(('PartMC','Barrel'),loc='upper left')
filename_out = "aero_mass_size.pdf"
figure.savefig(filename_out)