#!/bin/bash

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $SCRIPTDIR/common.sh

if [[ -z $(which ${MKFS_UBIFS}) ]]; then
  echo "Could not find ${MKFS_UBIFS} in path."
  echo "Install it with the CHIP-SDK setup script."
  echo "You will also need to run this script as root."
  exit 1
fi

UBOOTDIR="$1"
ROOTFSTAR="$2"
OUTPUTDIR="$3"

# build the UBI image
prepare_ubi() {
  local outputdir="$1"
  local _ROOTFS_TAR="$2"
  local nandtype="$3"
  local maxlebcount="$4"
  local eraseblocksize="$5"
  local pagesize="$6"
  local subpagesize="$7"
  local oobsize="$8"
  
  local _TMPDIR=`mktemp -d -t chip-ubi-XXXXXX`
  local _ROOTFS=$_TMPDIR/rootfs
  local _EMPTYFS=$_TMPDIR/emptyfs
  local _ROOTCONFIGFS=$_TMPDIR/rootconffs
  local _ROOT_UBIFS=$_TMPDIR/root.ubifs
  local _EMPTY_UBIFS=$_TMPDIR/empty.ubifs
  local _ROOTCONFIG_UBIFS=$_TMPDIR/root-conf.ubifs
  local _UBINIZE_CFG=$_TMPDIR/ubinize.cfg

  mkdir -p "${_ROOTFS}" "${_EMPTYFS}" "${_ROOTCONFIGFS}"
  
  local ebsize=`printf %x $eraseblocksize`
  local psize=`printf %x $pagesize`
  local osize=`printf %x $oobsize`
  local ubi=$outputdir/chip-$ebsize-$psize-$osize.ubi
  local sparseubi=$outputdir/chip-$ebsize-$psize-$osize.ubi.sparse
  local mlcopts=""

  if [ -z $subpagesize ]; then
    subpagesize=$pagesize
  fi

  if [ "$nandtype" = "mlc" ]; then
    lebsize=$((eraseblocksize/2-$pagesize*2))
    mlcopts="-M dist3"
  elif [ $subpagesize -lt $pagesize ]; then
    lebsize=$((eraseblocksize-pagesize))
  else
    lebsize=$((eraseblocksize-pagesize*2))
  fi
  
  if [ "$osize" = "100" ]; then
    #TOSH_512_SLC
    echo "ERROR: This is not supported yet because of flash size"
    exit 1
  elif [ "$osize" = "500" ]; then
    #TOSH_4GB_MLC
    root_size="500MiB"
    data_size="2500MiB"
  elif [ "$osize" = "680" ]; then
    #HYNI_8GB_MLC
    root_size="500MiB"
    vol_size="6000MiB"
  else
	echo "Unable to acquire appropriate volume size or flags, quitting!"
	exit 1
  fi

# Create root ubifs 
  tar -xf "${_ROOTFS_TAR}" -C "${_ROOTFS}"
  ${MKFS_UBIFS} -d "${_ROOTFS}" -m $pagesize -e $lebsize -c $maxlebcount -o "${_ROOT_UBIFS}"

# Create empty ubifs 
  ${MKFS_UBIFS} -d "${_EMPTYFS}" -m $pagesize -e $lebsize -c $maxlebcount -o "${_EMPTY_UBIFS}"

  touch "${_ROOTCONFIGFS}/primary-rootfs"
  ${MKFS_UBIFS} -d "${_ROOTCONFIGFS}" -m $pagesize -e $lebsize -c $maxlebcount -o "${_ROOTCONFIG_UBIFS}"


  echo "
[primary-rootfs]
mode=ubi
vol_id=0
vol_type=dynamic
vol_size=$root_size
vol_name=primary-rootfs
vol_alignment=1
image=${_ROOT_UBIFS}

[secondary-rootfs]
mode=ubi
vol_id=1
vol_type=dynamic
vol_size=$root_size
vol_name=secondary-rootfs
vol_alignment=1
image=${_ROOT_UBIFS}

[root-config]
mode=ubi
vol_id=2
vol_type=dynamic
vol_size=50MiB
vol_name=root-config
vol_alignment=1
image=${_ROOTCONFIG_UBIFS}

[secure-data]
mode=ubi
vol_id=3
vol_type=dynamic
vol_size=50MiB
vol_name=secure-data
vol_alignment=1
image=${_EMPTY_UBIFS}

[data]
mode=ubi
vol_id=4
vol_type=dynamic
vol_size=$data_size
vol_name=data
vol_alignment=1
image=${_EMPTY_UBIFS}
" > ${_UBINIZE_CFG}


  ubinize -o $ubi -p $eraseblocksize -m $pagesize -s $subpagesize $mlcopts "${_UBINIZE_CFG}"
  img2simg $ubi $sparseubi $eraseblocksize
  rm -rf $_TMPDIR
}

# build the SPL image
prepare_spl() {
  local _TMPDIR=`mktemp -d -t chip-spl-XXXXXX`
  local outputdir=$1
  local spl=$2
  local eraseblocksize=$3
  local pagesize=$4
  local oobsize=$5
  local repeat=$((eraseblocksize/pagesize/64))
  local nandspl=$_TMPDIR/nand-spl.bin
  local nandpaddedspl=$_TMPDIR/nand-padded-spl.bin
  local ebsize=`printf %x $eraseblocksize`
  local psize=`printf %x $pagesize`
  local osize=`printf %x $oobsize`
  local nandrepeatedspl=$outputdir/spl-$ebsize-$psize-$osize.bin
  local padding=$_TMPDIR/padding
  local splpadding=$_TMPDIR/nand-spl-padding

  ${SNIB} -c 64/1024 -p $pagesize -o $oobsize -u 1024 -e $eraseblocksize -b -s $spl $nandspl

  local splsize=`filesize $nandspl`
  local paddingsize=$((64-(splsize/(pagesize+oobsize))))
  local i=0

  while [ $i -lt $repeat ]; do
    dd if=/dev/urandom of=$padding bs=1024 count=$paddingsize
    ${SNIB} -c 64/1024 -p $pagesize -o $oobsize -u 1024 -e $eraseblocksize -b -s $padding $splpadding
    cat $nandspl $splpadding > $nandpaddedspl

    if [ "$i" -eq "0" ]; then
      cat $nandpaddedspl > $nandrepeatedspl
    else
      cat $nandpaddedspl >> $nandrepeatedspl
    fi

    i=$((i+1))
  done

  rm -rf $_TMPDIR
}

# build the bootloader image
prepare_uboot() {
  local outputdir=$1
  local uboot=$2
  local eraseblocksize=$3
  local ebsize=`printf %x $eraseblocksize`
  local paddeduboot=$outputdir/uboot-$ebsize.bin

  dd if=$uboot of=$paddeduboot bs=$eraseblocksize conv=sync
}

## copy the source images in the output dir ##
mkdir -p $OUTPUTDIR
cp $UBOOTDIR/spl/sunxi-spl.bin $OUTPUTDIR/
cp $UBOOTDIR/u-boot-dtb.bin $OUTPUTDIR/
cp $ROOTFSTAR $OUTPUTDIR

## prepare ubi images ##
# Toshiba SLC image:
#prepare_ubi $OUTPUTDIR $ROOTFSTAR "slc" 2048 262144 4096 1024 256
# Toshiba MLC image:
prepare_ubi $OUTPUTDIR $ROOTFSTAR "mlc" 4096 4194304 16384 16384 1280
# Hynix MLC image:
prepare_ubi $OUTPUTDIR $ROOTFSTAR "mlc" 4096 4194304 16384 16384 1664

## prepare spl images ##
# Toshiba SLC image:
prepare_spl $OUTPUTDIR $UBOOTDIR/spl/sunxi-spl.bin 262144 4096 256
# Toshiba MLC image:
prepare_spl $OUTPUTDIR $UBOOTDIR/spl/sunxi-spl.bin 4194304 16384 1280
# Hynix MLC image:
prepare_spl $OUTPUTDIR $UBOOTDIR/spl/sunxi-spl.bin 4194304 16384 1664

## prepare uboot images ##
# Toshiba SLC image:
prepare_uboot $OUTPUTDIR $UBOOTDIR/u-boot-dtb.bin 262144
# Toshiba/Hynix MLC image:
prepare_uboot $OUTPUTDIR $UBOOTDIR/u-boot-dtb.bin 4194304
