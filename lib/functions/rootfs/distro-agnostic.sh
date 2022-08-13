function install_distribution_agnostic() {
	display_alert "Installing distro-agnostic part of rootfs" "install_distribution_agnostic" "debug"

	# install rootfs encryption related packages separate to not break packages cache
	# @TODO: terrible, this does not use apt-cacher, extract to extension and fix
	if [[ $CRYPTROOT_ENABLE == yes ]]; then
		display_alert "Installing rootfs encryption related packages" "cryptsetup" "info"
		chroot_sdcard_apt_get_install cryptsetup
		if [[ $CRYPTROOT_SSH_UNLOCK == yes ]]; then
			display_alert "Installing rootfs encryption related packages" "dropbear-initramfs" "info"
			chroot_sdcard_apt_get_install dropbear-initramfs cryptsetup-initramfs
		fi

	fi

	# add dummy fstab entry to make mkinitramfs happy
	echo "/dev/mmcblk0p1 / $ROOTFS_TYPE defaults 0 1" >> "${SDCARD}"/etc/fstab
	# required for initramfs-tools-core on Stretch since it ignores the / fstab entry
	echo "/dev/mmcblk0p2 /usr $ROOTFS_TYPE defaults 0 2" >> "${SDCARD}"/etc/fstab

	# @TODO: refacctor this into cryptroot extension
	# adjust initramfs dropbear configuration
	# needs to be done before kernel installation, else it won't be in the initrd image
	if [[ $CRYPTROOT_ENABLE == yes && $CRYPTROOT_SSH_UNLOCK == yes ]]; then
		# Set the port of the dropbear ssh daemon in the initramfs to a different one if configured
		# this avoids the typical 'host key changed warning' - `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`
		[[ -f "${SDCARD}"/etc/dropbear-initramfs/config ]] &&
			sed -i 's/^#DROPBEAR_OPTIONS=/DROPBEAR_OPTIONS="-p '"${CRYPTROOT_SSH_UNLOCK_PORT}"'"/' \
				"${SDCARD}"/etc/dropbear-initramfs/config

		# setup dropbear authorized_keys, either provided by userpatches or generated
		if [[ -f $USERPATCHES_PATH/dropbear_authorized_keys ]]; then
			cp "$USERPATCHES_PATH"/dropbear_authorized_keys "${SDCARD}"/etc/dropbear-initramfs/authorized_keys
		else
			# generate a default ssh key for login on dropbear in initramfs
			# this key should be changed by the user on first login
			display_alert "Generating a new SSH key pair for dropbear (initramfs)" "" ""
			ssh-keygen -t ecdsa -f "${SDCARD}"/etc/dropbear-initramfs/id_ecdsa \
				-N '' -O force-command=cryptroot-unlock -C 'AUTOGENERATED_BY_ARMBIAN_BUILD' 2>&1

			# /usr/share/initramfs-tools/hooks/dropbear will automatically add 'id_ecdsa.pub' to authorized_keys file
			# during mkinitramfs of update-initramfs
			#cat "${SDCARD}"/etc/dropbear-initramfs/id_ecdsa.pub > "${SDCARD}"/etc/dropbear-initramfs/authorized_keys
			CRYPTROOT_SSH_UNLOCK_KEY_NAME="${VENDOR}_${REVISION}_${BOARD^}_${RELEASE}_${BRANCH}_${VER/-$LINUXFAMILY/}_${DESKTOP_ENVIRONMENT}".key
			# copy dropbear ssh key to image output dir for convenience
			cp "${SDCARD}"/etc/dropbear-initramfs/id_ecdsa "${DEST}/images/${CRYPTROOT_SSH_UNLOCK_KEY_NAME}"
			display_alert "SSH private key for dropbear (initramfs) has been copied to:" \
				"$DEST/images/$CRYPTROOT_SSH_UNLOCK_KEY_NAME" "info"
		fi
	fi

	# create modules file
	local modules=MODULES_${BRANCH^^}
	if [[ -n "${!modules}" ]]; then
		tr ' ' '\n' <<< "${!modules}" > "${SDCARD}"/etc/modules
	elif [[ -n "${MODULES}" ]]; then
		tr ' ' '\n' <<< "${MODULES}" > "${SDCARD}"/etc/modules
	fi

	# create blacklist files
	local blacklist=MODULES_BLACKLIST_${BRANCH^^}
	if [[ -n "${!blacklist}" ]]; then
		tr ' ' '\n' <<< "${!blacklist}" | sed -e 's/^/blacklist /' > "${SDCARD}/etc/modprobe.d/blacklist-${BOARD}.conf"
	elif [[ -n "${MODULES_BLACKLIST}" ]]; then
		tr ' ' '\n' <<< "${MODULES_BLACKLIST}" | sed -e 's/^/blacklist /' > "${SDCARD}/etc/modprobe.d/blacklist-${BOARD}.conf"
	fi

	# configure MIN / MAX speed for cpufrequtils
	cat <<- EOF > "${SDCARD}"/etc/default/cpufrequtils
		ENABLE=true
		MIN_SPEED=$CPUMIN
		MAX_SPEED=$CPUMAX
		GOVERNOR=$GOVERNOR
	EOF

	# remove default interfaces file if present
	# before installing board support package
	rm -f "${SDCARD}"/etc/network/interfaces

	# disable selinux by default
	mkdir -p "${SDCARD}"/selinux
	[[ -f "${SDCARD}"/etc/selinux/config ]] && sed "s/^SELINUX=.*/SELINUX=disabled/" -i "${SDCARD}"/etc/selinux/config

	# remove Ubuntu's legal text
	[[ -f "${SDCARD}"/etc/legal ]] && rm "${SDCARD}"/etc/legal

	# Prevent loading paralel printer port drivers which we don't need here.
	# Suppress boot error if kernel modules are absent
	if [[ -f "${SDCARD}"/etc/modules-load.d/cups-filters.conf ]]; then
		sed "s/^lp/#lp/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
		sed "s/^ppdev/#ppdev/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
		sed "s/^parport_pc/#parport_pc/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
	fi

	# console fix due to Debian bug
	sed -e 's/CHARMAP=".*"/CHARMAP="'$CONSOLE_CHAR'"/g' -i "${SDCARD}"/etc/default/console-setup

	# add the /dev/urandom path to the rng config file
	echo "HRNGDEVICE=/dev/urandom" >> "${SDCARD}"/etc/default/rng-tools

	# @TODO: security problem?
	# ping needs privileged action to be able to create raw network socket
	# this is working properly but not with (at least) Debian Buster
	chroot "${SDCARD}" /bin/bash -c "chmod u+s /bin/ping" 2>&1

	# change time zone data
	echo "${TZDATA}" > "${SDCARD}"/etc/timezone
	# @TODO: a more generic logging helper needed
	chroot "${SDCARD}" /bin/bash -c "dpkg-reconfigure -f noninteractive tzdata" 2>&1

	# set root password
	chroot "${SDCARD}" /bin/bash -c "(echo $ROOTPWD;echo $ROOTPWD;) | passwd root >/dev/null 2>&1"

	# enable automated login to console(s)
	if [[ $CONSOLE_AUTOLOGIN == yes ]]; then
		mkdir -p "${SDCARD}"/etc/systemd/system/getty@.service.d/
		mkdir -p "${SDCARD}"/etc/systemd/system/serial-getty@.service.d/
		# @TODO: check why there was a sleep 10s in ExecStartPre
		cat <<- EOF > "${SDCARD}"/etc/systemd/system/serial-getty@.service.d/override.conf
			[Service]
			ExecStart=
			ExecStart=-/sbin/agetty --noissue --autologin root %I \$TERM
			Type=idle
		EOF
		cp "${SDCARD}"/etc/systemd/system/serial-getty@.service.d/override.conf "${SDCARD}"/etc/systemd/system/getty@.service.d/override.conf
	fi

	# force change root password at first login
	#chroot "${SDCARD}" /bin/bash -c "chage -d 0 root"

	# change console welcome text
	echo -e "${VENDOR} ${REVISION} ${RELEASE^} \\l \n" > "${SDCARD}"/etc/issue
	echo "${VENDOR} ${REVISION} ${RELEASE^}" > "${SDCARD}"/etc/issue.net
	sed -i "s/^PRETTY_NAME=.*/PRETTY_NAME=\"${VENDOR} $REVISION "${RELEASE^}"\"/" "${SDCARD}"/etc/os-release

	# enable few bash aliases enabled in Ubuntu by default to make it even
	sed "s/#alias ll='ls -l'/alias ll='ls -l'/" -i "${SDCARD}"/etc/skel/.bashrc
	sed "s/#alias la='ls -A'/alias la='ls -A'/" -i "${SDCARD}"/etc/skel/.bashrc
	sed "s/#alias l='ls -CF'/alias l='ls -CF'/" -i "${SDCARD}"/etc/skel/.bashrc
	# root user is already there. Copy bashrc there as well
	cp "${SDCARD}"/etc/skel/.bashrc "${SDCARD}"/root

	# display welcome message at first root login @TODO: what reads this?
	touch "${SDCARD}"/root/.not_logged_in_yet

	if [[ ${DESKTOP_AUTOLOGIN} == yes ]]; then
		# set desktop autologin
		touch "${SDCARD}"/root/.desktop_autologin
	fi

	# NOTE: this needs to be executed before family_tweaks
	local bootscript_src=${BOOTSCRIPT%%:*}
	local bootscript_dst=${BOOTSCRIPT##*:}

	# create extlinux config file @TODO: refactor into extensions u-boot, extlinux
	if [[ $SRC_EXTLINUX == yes ]]; then
		display_alert "Using extlinux, SRC_EXTLINUX: ${SRC_EXTLINUX}" "image will be incompatible with nand-sata-install" "warn"
		mkdir -p $SDCARD/boot/extlinux
		local bootpart_prefix
		if [[ -n $BOOTFS_TYPE ]]; then
			bootpart_prefix=/
		else
			bootpart_prefix=/boot/
		fi
		cat <<- EOF > "$SDCARD/boot/extlinux/extlinux.conf"
			label ${VENDOR}
			  kernel ${bootpart_prefix}$NAME_KERNEL
			  initrd ${bootpart_prefix}$NAME_INITRD
		EOF
		if [[ -n $BOOT_FDT_FILE ]]; then
			if [[ $BOOT_FDT_FILE != "none" ]]; then
				echo "  fdt ${bootpart_prefix}dtb/$BOOT_FDT_FILE" >> "$SDCARD/boot/extlinux/extlinux.conf"
			fi
		else
			echo "  fdtdir ${bootpart_prefix}dtb/" >> "$SDCARD/boot/extlinux/extlinux.conf"
		fi
	else # ... not extlinux ...

		if [[ -n "${BOOTSCRIPT}" && "${BOOTCONFIG}" != "none" ]]; then
			if [ -f "${USERPATCHES_PATH}/bootscripts/${bootscript_src}" ]; then
				run_host_command_logged cp -pv "${USERPATCHES_PATH}/bootscripts/${bootscript_src}" "${SDCARD}/boot/${bootscript_dst}"
			else
				run_host_command_logged cp -pv "${SRC}/config/bootscripts/${bootscript_src}" "${SDCARD}/boot/${bootscript_dst}"
			fi
		fi

		if [[ -n $BOOTENV_FILE ]]; then
			if [[ -f $USERPATCHES_PATH/bootenv/$BOOTENV_FILE ]]; then
				run_host_command_logged cp -pv "$USERPATCHES_PATH/bootenv/${BOOTENV_FILE}" "${SDCARD}"/boot/armbianEnv.txt
			elif [[ -f $SRC/config/bootenv/$BOOTENV_FILE ]]; then
				run_host_command_logged cp -pv "${SRC}/config/bootenv/${BOOTENV_FILE}" "${SDCARD}"/boot/armbianEnv.txt
			fi
		fi

		# TODO: modify $bootscript_dst or armbianEnv.txt to make NFS boot universal
		# instead of copying sunxi-specific template
		if [[ $ROOTFS_TYPE == nfs ]]; then
			display_alert "Copying NFS boot script template"
			if [[ -f $USERPATCHES_PATH/nfs-boot.cmd ]]; then
				run_host_command_logged cp -pv "$USERPATCHES_PATH"/nfs-boot.cmd "${SDCARD}"/boot/boot.cmd
			else
				run_host_command_logged cp -pv "${SRC}"/config/templates/nfs-boot.cmd.template "${SDCARD}"/boot/boot.cmd
			fi
		fi

		[[ -n $OVERLAY_PREFIX && -f "${SDCARD}"/boot/armbianEnv.txt ]] &&
			echo "overlay_prefix=$OVERLAY_PREFIX" >> "${SDCARD}"/boot/armbianEnv.txt

		[[ -n $DEFAULT_OVERLAYS && -f "${SDCARD}"/boot/armbianEnv.txt ]] &&
			echo "overlays=${DEFAULT_OVERLAYS//,/ }" >> "${SDCARD}"/boot/armbianEnv.txt

		[[ -n $BOOT_FDT_FILE && -f "${SDCARD}"/boot/armbianEnv.txt ]] &&
			echo "fdtfile=${BOOT_FDT_FILE}" >> "${SDCARD}/boot/armbianEnv.txt"

	fi

	# initial date for fake-hwclock
	date -u '+%Y-%m-%d %H:%M:%S' > "${SDCARD}"/etc/fake-hwclock.data

	echo "${HOST}" > "${SDCARD}"/etc/hostname

	# set hostname in hosts file
	cat <<- EOF > "${SDCARD}"/etc/hosts
		127.0.0.1   localhost
		127.0.1.1   $HOST
		::1         localhost $HOST ip6-localhost ip6-loopback
		fe00::0     ip6-localnet
		ff00::0     ip6-mcastprefix
		ff02::1     ip6-allnodes
		ff02::2     ip6-allrouters
	EOF

	cd "${SRC}" || exit_with_error "cray-cray about ${SRC}"

	# LOGGING: we're running under the logger framework here.
	# LOGGING: so we just log directly to stdout and let it handle it.
	# LOGGING: redirect commands' stderr to stdout so it goes into the log, not screen.

	display_alert "Temporarily disabling" "initramfs-tools hook for kernel"
	chroot_sdcard chmod -v -x /etc/kernel/postinst.d/initramfs-tools

	display_alert "Cleaning" "package lists"
	APT_OPTS="y" chroot_sdcard_apt_get clean

	display_alert "Updating" "apt package lists"
	APT_OPTS="y" do_with_retries 3 chroot_sdcard_apt_get update

	# install family packages
	if [[ -n ${PACKAGE_LIST_FAMILY} ]]; then
		_pkg_list=${PACKAGE_LIST_FAMILY}
		display_alert "Installing PACKAGE_LIST_FAMILY packages" "${_pkg_list}"
		# shellcheck disable=SC2086 # we need to expand here. retry 3 times download-only to counter apt-cacher-ng failures.
		do_with_retries 3 chroot_sdcard_apt_get_install_download_only ${_pkg_list}

		# shellcheck disable=SC2086 # we need to expand here.
		chroot_sdcard_apt_get_install ${_pkg_list}
	fi

	# install board packages
	if [[ -n ${PACKAGE_LIST_BOARD} ]]; then
		_pkg_list=${PACKAGE_LIST_BOARD}
		display_alert "Installing PACKAGE_LIST_BOARD packages" "${_pkg_list}"
		# shellcheck disable=SC2086 # we need to expand here. retry 3 times download-only to counter apt-cacher-ng failures.
		do_with_retries 3 chroot_sdcard_apt_get_install_download_only ${_pkg_list}

		# shellcheck disable=SC2086 # we need to expand.
		chroot_sdcard_apt_get_install ${_pkg_list}
	fi

	# remove family packages
	if [[ -n ${PACKAGE_LIST_FAMILY_REMOVE} ]]; then
		_pkg_list=${PACKAGE_LIST_FAMILY_REMOVE}
		display_alert "Removing PACKAGE_LIST_FAMILY_REMOVE packages" "${_pkg_list}"
		chroot_sdcard_apt_get remove --auto-remove ${_pkg_list}
	fi

	# remove board packages. loop over the list to remove, check if they're actually installed, then remove individually.
	if [[ -n ${PACKAGE_LIST_BOARD_REMOVE} ]]; then
		_pkg_list=${PACKAGE_LIST_BOARD_REMOVE}
		declare -a currently_installed_packages
		# shellcheck disable=SC2207 # I wanna split, thanks.
		currently_installed_packages=($(chroot_sdcard_with_stdout dpkg-query --show --showformat='${Package} '))
		for PKG_REMOVE in ${_pkg_list}; do
			# shellcheck disable=SC2076 # I wanna match literally, thanks.
			if [[ " ${currently_installed_packages[*]} " =~ " ${PKG_REMOVE} " ]]; then
				display_alert "Removing PACKAGE_LIST_BOARD_REMOVE package" "${PKG_REMOVE}"
				chroot_sdcard_apt_get remove --auto-remove "${PKG_REMOVE}"
			fi
		done
		unset currently_installed_packages
	fi

	# install u-boot
	# @TODO: add install_bootloader() extension method, refactor into u-boot extension
	[[ "${BOOTCONFIG}" != "none" ]] && {
		if [[ "${REPOSITORY_INSTALL}" != *u-boot* ]]; then
			UBOOT_VER=$(dpkg --info "${DEB_STORAGE}/${CHOSEN_UBOOT}_${REVISION}_${ARCH}.deb" | grep Descr | awk '{print $(NF)}')
			install_deb_chroot "${DEB_STORAGE}/${CHOSEN_UBOOT}_${REVISION}_${ARCH}.deb"
		else
			install_deb_chroot "linux-u-boot-${BOARD}-${BRANCH}" "remote" "yes"
			UBOOT_REPO_VERSION=$(dpkg-deb -f "${SDCARD}"/var/cache/apt/archives/linux-u-boot-${BOARD}-${BRANCH}*_${ARCH}.deb Version)
		fi
	}

	call_extension_method "pre_install_kernel_debs" <<- 'PRE_INSTALL_KERNEL_DEBS'
		*called before installing the Armbian-built kernel deb packages*
		It is not too late to `unset KERNELSOURCE` here and avoid kernel install.
	PRE_INSTALL_KERNEL_DEBS

	# default VER, will be parsed from Kernel version in the installed deb package.
	VER="linux"

	# install kernel
	[[ -n $KERNELSOURCE ]] && {
		if [[ "${REPOSITORY_INSTALL}" != *kernel* ]]; then
			VER=$(dpkg --info "${DEB_STORAGE}/${CHOSEN_KERNEL}_${REVISION}_${ARCH}.deb" | grep "^ Source:" | sed -e 's/ Source: linux-//')
			display_alert "Parsed kernel version from local package" "${VER}" "debug"

			install_deb_chroot "${DEB_STORAGE}/${CHOSEN_KERNEL}_${REVISION}_${ARCH}.deb"
			if [[ -f ${DEB_STORAGE}/${CHOSEN_KERNEL/image/dtb}_${REVISION}_${ARCH}.deb ]]; then
				install_deb_chroot "${DEB_STORAGE}/${CHOSEN_KERNEL/image/dtb}_${REVISION}_${ARCH}.deb"
			fi
			if [[ $INSTALL_HEADERS == yes ]]; then
				install_deb_chroot "${DEB_STORAGE}/${CHOSEN_KERNEL/image/headers}_${REVISION}_${ARCH}.deb"
			fi
		else
			install_deb_chroot "linux-image-${BRANCH}-${LINUXFAMILY}" "remote"
			VER=$(dpkg-deb -f "${SDCARD}"/var/cache/apt/archives/linux-image-${BRANCH}-${LINUXFAMILY}*_${ARCH}.deb Source)
			VER="${VER/-$LINUXFAMILY/}"
			VER="${VER/linux-/}"
			display_alert "Parsed kernel version from remote package" "${VER}" "debug"
			if [[ "${ARCH}" != "amd64" && "${LINUXFAMILY}" != "media" ]]; then # amd64 does not have dtb package, see packages/armbian/builddeb:355
				install_deb_chroot "linux-dtb-${BRANCH}-${LINUXFAMILY}" "remote"
			fi
			[[ $INSTALL_HEADERS == yes ]] && install_deb_chroot "linux-headers-${BRANCH}-${LINUXFAMILY}" "remote"
		fi
	}

	call_extension_method "post_install_kernel_debs" <<- 'POST_INSTALL_KERNEL_DEBS'
		*allow config to do more with the installed kernel/headers*
		Called after packages, u-boot, kernel and headers installed in the chroot, but before the BSP is installed.
		If `KERNELSOURCE` is (still?) unset after this, Armbian-built firmware will not be installed.
	POST_INSTALL_KERNEL_DEBS

	# install board support packages
	if [[ "${REPOSITORY_INSTALL}" != *bsp* ]]; then
		install_deb_chroot "${DEB_STORAGE}/${BSP_CLI_PACKAGE_FULLNAME}.deb"
	else
		install_deb_chroot "${CHOSEN_ROOTFS}" "remote"
	fi

	# install armbian-desktop
	if [[ "${REPOSITORY_INSTALL}" != *armbian-desktop* ]]; then
		if [[ $BUILD_DESKTOP == yes ]]; then
			install_deb_chroot "${DEB_STORAGE}/${RELEASE}/${CHOSEN_DESKTOP}_${REVISION}_all.deb"
			install_deb_chroot "${DEB_STORAGE}/${RELEASE}/${BSP_DESKTOP_PACKAGE_FULLNAME}.deb"
			# install display manager and PACKAGE_LIST_DESKTOP_FULL packages if enabled per board
			desktop_postinstall
		fi
	else
		if [[ $BUILD_DESKTOP == yes ]]; then
			install_deb_chroot "${CHOSEN_DESKTOP}" "remote"
			# install display manager and PACKAGE_LIST_DESKTOP_FULL packages if enabled per board
			desktop_postinstall
		fi
	fi

	# install armbian-firmware by default. Set BOARD_FIRMWARE_INSTALL="-full" to install full firmware variant
	[[ "${INSTALL_ARMBIAN_FIRMWARE:-yes}" == "yes" ]] && {
		if [[ "${REPOSITORY_INSTALL}" != *armbian-firmware* ]]; then
			if [[ -f ${DEB_STORAGE}/armbian-firmware_${REVISION}_all.deb ]]; then
				install_deb_chroot "${DEB_STORAGE}/armbian-firmware${BOARD_FIRMWARE_INSTALL:-""}_${REVISION}_all.deb"
			fi
		else
			install_deb_chroot "armbian-firmware${BOARD_FIRMWARE_INSTALL:-""}" "remote"
		fi
	}

	# install armbian-config
	if [[ "${PACKAGE_LIST_RM}" != *armbian-config* ]]; then
		if [[ "${REPOSITORY_INSTALL}" != *armbian-config* ]]; then
			if [[ $BUILD_MINIMAL != yes ]]; then
				install_deb_chroot "${DEB_STORAGE}/armbian-config_${REVISION}_all.deb"
			fi
		else
			if [[ $BUILD_MINIMAL != yes ]]; then
				install_deb_chroot "armbian-config" "remote"
			fi
		fi
	fi

	# install armbian-zsh
	if [[ "${PACKAGE_LIST_RM}" != *armbian-zsh* ]]; then
		if [[ "${REPOSITORY_INSTALL}" != *armbian-zsh* ]]; then
			if [[ $BUILD_MINIMAL != yes ]]; then
				install_deb_chroot "${DEB_STORAGE}/armbian-zsh_${REVISION}_all.deb"
			fi
		else
			if [[ $BUILD_MINIMAL != yes ]]; then
				install_deb_chroot "armbian-zsh" "remote"
			fi
		fi
	fi

	# install plymouth-theme-armbian
	if [[ $PLYMOUTH == yes ]]; then
		if [[ "${REPOSITORY_INSTALL}" != *plymouth-theme-armbian* ]]; then
			install_deb_chroot "${DEB_STORAGE}/armbian-plymouth-theme_${REVISION}_all.deb"
		else
			install_deb_chroot "armbian-plymouth-theme" "remote"
		fi
	fi

	# install kernel sources
	if [[ -f ${DEB_STORAGE}/${CHOSEN_KSRC}_${REVISION}_all.deb && $INSTALL_KSRC == yes ]]; then
		install_deb_chroot "${DEB_STORAGE}/${CHOSEN_KSRC}_${REVISION}_all.deb"
	fi

	# install wireguard tools
	if [[ $WIREGUARD == yes ]]; then
		install_deb_chroot "wireguard-tools" "remote"
	fi

	# freeze armbian packages
	if [[ $BSPFREEZE == yes ]]; then
		display_alert "Freezing Armbian packages" "$BOARD" "info"
		chroot "${SDCARD}" /bin/bash -c "apt-mark hold ${CHOSEN_KERNEL} ${CHOSEN_KERNEL/image/headers} \
		linux-u-boot-${BOARD}-${BRANCH} ${CHOSEN_KERNEL/image/dtb}" 2>&1
	fi

	# remove deb files
	rm -f "${SDCARD}"/root/*.deb

	# copy boot splash images
	cp "${SRC}"/packages/blobs/splash/armbian-u-boot.bmp "${SDCARD}"/boot/boot.bmp

	# execute $LINUXFAMILY-specific tweaks
	if [[ $(type -t family_tweaks) == function ]]; then
		display_alert "Running family_tweaks" "$BOARD :: $LINUXFAMILY" "debug"
		family_tweaks
		display_alert "Done with family_tweaks" "$BOARD :: $LINUXFAMILY" "debug"
	fi

	call_extension_method "post_family_tweaks" <<- 'FAMILY_TWEAKS'
		*customize the tweaks made by $LINUXFAMILY-specific family_tweaks*
		It is run after packages are installed in the rootfs, but before enabling additional services.
		It allows implementors access to the rootfs (`${SDCARD}`) in its pristine state after packages are installed.
	FAMILY_TWEAKS

	# enable additional services, if they exist.
	display_alert "Enabling Armbian services" "systemd" "info"
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-firstrun.service ]] && chroot_sdcard systemctl --no-reload enable armbian-firstrun.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-firstrun-config.service ]] && chroot_sdcard systemctl --no-reload enable armbian-firstrun-config.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-zram-config.service ]] && chroot_sdcard systemctl --no-reload enable armbian-zram-config.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-hardware-optimize.service ]] && chroot_sdcard systemctl --no-reload enable armbian-hardware-optimize.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-ramlog.service ]] && chroot_sdcard systemctl --no-reload enable armbian-ramlog.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-resize-filesystem.service ]] && chroot_sdcard systemctl --no-reload enable armbian-resize-filesystem.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-hardware-monitor.service ]] && chroot_sdcard systemctl --no-reload enable armbian-hardware-monitor.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-led-state.service ]] && chroot_sdcard systemctl --no-reload enable armbian-led-state.service

	# copy "first run automated config, optional user configured"
	cp "${SRC}"/packages/bsp/armbian_first_run.txt.template "${SDCARD}"/boot/armbian_first_run.txt.template

	# switch to beta repository at this stage if building nightly images
	[[ $IMAGE_TYPE == nightly ]] && sed -i 's/apt/beta/' "${SDCARD}"/etc/apt/sources.list.d/armbian.list

	# fix for https://bugs.launchpad.net/ubuntu/+source/blueman/+bug/1542723 @TODO: from ubuntu 15. maybe gone?
	chroot "${SDCARD}" /bin/bash -c "chown root:messagebus /usr/lib/dbus-1.0/dbus-daemon-launch-helper"
	chroot "${SDCARD}" /bin/bash -c "chmod u+s /usr/lib/dbus-1.0/dbus-daemon-launch-helper"

	# disable samba NetBIOS over IP name service requests since it hangs when no network is present at boot
	chroot "${SDCARD}" /bin/bash -c "systemctl --quiet disable nmbd 2> /dev/null"

	# disable low-level kernel messages for non betas
	if [[ -z $BETA ]]; then
		sed -i "s/^#kernel.printk*/kernel.printk/" "${SDCARD}"/etc/sysctl.conf
	fi

	# disable repeated messages due to xconsole not being installed.
	[[ -f "${SDCARD}"/etc/rsyslog.d/50-default.conf ]] &&
		sed '/daemon\.\*\;mail.*/,/xconsole/ s/.*/#&/' -i "${SDCARD}"/etc/rsyslog.d/50-default.conf

	# disable deprecated parameter
	[[ -f "${SDCARD}"/etc/rsyslog.conf ]] &&
		sed '/.*$KLogPermitNonKernelFacility.*/,// s/.*/#&/' -i "${SDCARD}"/etc/rsyslog.conf

	# enable getty on multiple serial consoles
	# and adjust the speed if it is defined and different than 115200
	#
	# example: SERIALCON="ttyS0:15000000,ttyGS1"
	#
	ifs=$IFS
	for i in $(echo "${SERIALCON:-'ttyS0'}" | sed "s/,/ /g"); do
		IFS=':' read -r -a array <<< "$i"
		[[ "${array[0]}" == "tty1" ]] && continue # Don't enable tty1 as serial console.
		display_alert "Enabling serial console" "${array[0]}" "info"
		# add serial console to secure tty list
		[ -z "$(grep -w '^${array[0]}' "${SDCARD}"/etc/securetty 2> /dev/null)" ] &&
			echo "${array[0]}" >> "${SDCARD}"/etc/securetty
		if [[ ${array[1]} != "115200" && -n ${array[1]} ]]; then
			# make a copy, fix speed and enable
			cp "${SDCARD}"/lib/systemd/system/serial-getty@.service \
				"${SDCARD}/lib/systemd/system/serial-getty@${array[0]}.service"
			sed -i "s/--keep-baud 115200/--keep-baud ${array[1]},115200/" \
				"${SDCARD}/lib/systemd/system/serial-getty@${array[0]}.service"
		fi
		chroot_sdcard systemctl daemon-reload
		chroot_sdcard systemctl --no-reload enable "serial-getty@${array[0]}.service"
		if [[ "${array[0]}" == "ttyGS0" && $LINUXFAMILY == sun8i && $BRANCH == default ]]; then
			mkdir -p "${SDCARD}"/etc/systemd/system/serial-getty@ttyGS0.service.d
			cat <<- EOF > "${SDCARD}"/etc/systemd/system/serial-getty@ttyGS0.service.d/10-switch-role.conf
				[Service]
				ExecStartPre=-/bin/sh -c "echo 2 > /sys/bus/platform/devices/sunxi_usb_udc/otg_role"
			EOF
		fi
	done
	IFS=$ifs

	[[ $LINUXFAMILY == sun*i ]] && mkdir -p "${SDCARD}"/boot/overlay-user

	# to prevent creating swap file on NFS (needs specific kernel options)
	# and f2fs/btrfs (not recommended or needs specific kernel options)
	[[ $ROOTFS_TYPE != ext4 ]] && touch "${SDCARD}"/var/swap

	# install initial asound.state if defined
	mkdir -p "${SDCARD}"/var/lib/alsa/
	[[ -n $ASOUND_STATE ]] && cp "${SRC}/packages/blobs/asound.state/${ASOUND_STATE}" "${SDCARD}"/var/lib/alsa/asound.state

	# save initial armbian-release state
	cp "${SDCARD}"/etc/armbian-release "${SDCARD}"/etc/armbian-image-release

	# DNS fix. package resolvconf is not available everywhere
	if [ -d "${SDCARD}"/etc/resolvconf/resolv.conf.d ] && [ -n "$NAMESERVER" ]; then
		echo "nameserver $NAMESERVER" > "${SDCARD}"/etc/resolvconf/resolv.conf.d/head
	fi

	# permit root login via SSH for the first boot
	sed -i 's/#\?PermitRootLogin .*/PermitRootLogin yes/' "${SDCARD}"/etc/ssh/sshd_config

	# enable PubkeyAuthentication
	sed -i 's/#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "${SDCARD}"/etc/ssh/sshd_config

	if [ -f "${SDCARD}"/etc/NetworkManager/NetworkManager.conf ]; then
		# configure network manager
		sed "s/managed=\(.*\)/managed=true/g" -i "${SDCARD}"/etc/NetworkManager/NetworkManager.conf

		## remove network manager defaults to handle eth by default @TODO: why?
		rm -f "${SDCARD}"/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf

		# `systemd-networkd.service` will be enabled by `/lib/systemd/system-preset/90-systemd.preset` during first-run.
		# Mask it to avoid conflict
		chroot "${SDCARD}" /bin/bash -c "systemctl mask systemd-networkd.service" >> "${DEST}"/${LOG_SUBPATH}/install.log 2>&1

		# most likely we don't need to wait for nm to get online
		chroot_sdcard systemctl disable NetworkManager-wait-online.service

		# Just regular DNS and maintain /etc/resolv.conf as a file @TODO: this does not apply as of impish at least
		sed "/dns/d" -i "${SDCARD}"/etc/NetworkManager/NetworkManager.conf
		sed "s/\[main\]/\[main\]\ndns=default\nrc-manager=file/g" -i "${SDCARD}"/etc/NetworkManager/NetworkManager.conf

		if [[ -n $NM_IGNORE_DEVICES ]]; then
			mkdir -p "${SDCARD}"/etc/NetworkManager/conf.d/
			cat <<- EOF > "${SDCARD}"/etc/NetworkManager/conf.d/10-ignore-interfaces.conf
				[keyfile]
				unmanaged-devices=$NM_IGNORE_DEVICES
			EOF
		fi

	elif [ -d "${SDCARD}"/etc/systemd/network ]; then
		# configure networkd
		rm "${SDCARD}"/etc/resolv.conf
		ln -s /run/systemd/resolve/resolv.conf "${SDCARD}"/etc/resolv.conf

		# enable services
		chroot_sdcard systemctl enable systemd-networkd.service systemd-resolved.service

		# Mask `NetworkManager.service` to avoid conflict
		chroot "${SDCARD}" /bin/bash -c "systemctl mask NetworkManager.service" >> "${DEST}"/${LOG_SUBPATH}/install.log 2>&1

		if [ -e /etc/systemd/timesyncd.conf ]; then
			chroot_sdcard systemctl enable systemd-timesyncd.service
		fi
		umask 022
		cat > "${SDCARD}"/etc/systemd/network/eth0.network <<- __EOF__
			[Match]
			Name=eth0

			[Network]
			#MACAddress=
			DHCP=ipv4
			LinkLocalAddressing=ipv4
			#Address=192.168.1.100/24
			#Gateway=192.168.1.1
			#DNS=192.168.1.1
			#Domains=example.com
			NTP=0.pool.ntp.org 1.pool.ntp.org
		__EOF__

	fi

	# avahi daemon defaults if exists
	[[ -f "${SDCARD}"/usr/share/doc/avahi-daemon/examples/sftp-ssh.service ]] &&
		cp "${SDCARD}"/usr/share/doc/avahi-daemon/examples/sftp-ssh.service "${SDCARD}"/etc/avahi/services/
	[[ -f "${SDCARD}"/usr/share/doc/avahi-daemon/examples/ssh.service ]] &&
		cp "${SDCARD}"/usr/share/doc/avahi-daemon/examples/ssh.service "${SDCARD}"/etc/avahi/services/

	# nsswitch settings for sane DNS behavior: remove resolve, assure libnss-myhostname support
	sed "s/hosts\:.*/hosts:          files mymachines dns myhostname/g" -i "${SDCARD}"/etc/nsswitch.conf

	# build logo in any case
	boot_logo

	# Show logo
	if [[ $PLYMOUTH == yes ]]; then
		if [[ $BOOT_LOGO == yes || $BOOT_LOGO == desktop && $BUILD_DESKTOP == yes ]]; then
			[[ -f "${SDCARD}"/boot/armbianEnv.txt ]] && grep -q '^bootlogo' "${SDCARD}"/boot/armbianEnv.txt &&
				sed -i 's/^bootlogo.*/bootlogo=true/' "${SDCARD}"/boot/armbianEnv.txt ||
				echo 'bootlogo=true' >> "${SDCARD}"/boot/armbianEnv.txt

			[[ -f "${SDCARD}"/boot/boot.ini ]] &&
				sed -i 's/^setenv bootlogo.*/setenv bootlogo "true"/' "${SDCARD}"/boot/boot.ini
		fi
	fi

	# disable MOTD for first boot - we want as clean 1st run as possible
	chmod -x "${SDCARD}"/etc/update-motd.d/*

	return 0 # make sure to exit with success
}

install_rclocal() {
	cat <<- EOF > "${SDCARD}"/etc/rc.local
		#!/bin/sh -e
		#
		# rc.local
		#
		# This script is executed at the end of each multiuser runlevel.
		# Make sure that the script will "exit 0" on success or any other
		# value on error.
		#
		# In order to enable or disable this script just change the execution
		# bits.
		#
		# By default this script does nothing.

		exit 0
	EOF
	chmod +x "${SDCARD}"/etc/rc.local
}
