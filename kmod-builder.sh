#!/bin/bash -e

build_kernel_module() {
    local tmpdir="$1"
    local kver="$2"
    local kconf="$3"

    builddir=$(ls -d1 ${tmpdir}/build/kernel*/linux*)

    # Copy stock config and symvers to builddir
    find ${tmpdir}/dev -name Module.symvers -exec cp {} ${builddir} \;
    find ${tmpdir}/dev -name .config -exec cp {} ${builddir} \;

    # Find the kmod path and build
    pushd ${builddir} > /dev/null
    makefile=$(find -name Makefile -exec grep -H "${kconf}.*\.o" {} \; | cut -d: -f1)
    [[ -z ${makefile} ]] && echo "Missing Makefile for ${kconf}, exiting" && exit 1
    kmodpath=$(dirname ${makefile})
    kmodpath=${kmodpath/.\//}
    ./scripts/config --module ${kconf}
    sed -i "s/^EXTRAVERSION.*/EXTRAVERSION=-${kver#*-}/" Makefile
    make olddefconfig
    make modules_prepare
    make M=${kmodpath}
    popd > /dev/null
}

build_from_source_rpms() {
    local tmpdir="$1"
    local kver="$2"
    local kconf="$3"

    for rpm in src dev; do
        rpmdev-extract -qfC ${tmpdir}/${rpm} ${tmpdir}/kernel-${rpm}.rpm
    done

    kdir=$(basename ${tmpdir}/src/kernel*)

    rpmbuild -D "_sourcedir ${tmpdir}/src/${kdir}" \
             -D "_builddir ${tmpdir}/build" \
             -bp ${tmpdir}/src/${kdir}/kernel.spec --nodeps

    build_kernel_module "${tmpdir}" "${kver}" "${kconf}"
}

download_el_package() {
    local elver="$1"

    case ${elver} in
        7)
            dnf --repofrompath=r1,http://mirror.centos.org/centos/${elver}/os/x86_64/ \
                --repofrompath=r2,http://mirror.centos.org/centos/${elver}/updates/x86_64/ \
                --repoid=r1 --repoid=r2 \
                download kernel-devel-${kver}
            ;;
        8*)
            dnf --repofrompath=r1,http://mirror.centos.org/centos/8/BaseOS/x86_64/os \
                --repoid=r1 \
                download kernel-devel-${kver}

            ;;
    esac
}

build_el_module() {
    local tmpdir="$1"
    local kver="$2"
    local kconf="$3"

    tag=$(git ls-remote https://git.centos.org/rpms/kernel.git | \
          grep ${kver%.*}$ | awk '{print $2}')
    IFS=/ read -ra arr <<< "$tag"
    printf -v branch "/%s" "${arr[@]:2}"
    branch=${branch:1}

    pushd ${tmpdir} > /dev/null
    git clone --depth 1 https://git.centos.org/git/centos-git-common.git
    git clone --branch ${branch} --depth 1 https://git.centos.org/rpms/kernel.git

    download_el_package ${arr[3]:1} kernel-devel-${kver}
    rpmdev-extract -qfC ${tmpdir}/dev kernel-devel-${kver}.rpm

    pushd kernel > /dev/null
    ../centos-git-common/get_sources.sh -b ${arr[3]}
    rpmbuild -D "_topdir $(pwd)" -bp SPECS/kernel.spec  --nodeps
    popd > /dev/null

    mv kernel/BUILD/kernel* ${tmpdir}/build

    popd > /dev/null

    build_kernel_module "${tmpdir}" "${kver}" "${kconf}"
}


build_koji_module() {
    local tmpdir="$1"
    local kver="$2"
    local kconf="$3"
    local profile="$4"

    pushd ${tmpdir} > /dev/null
    koji -p ${profile} download-build --noprogress --rpm kernel-devel-${kver}
    koji -p ${profile} download-build --noprogress --rpm kernel-${kver%.*}.src

    mv kernel-devel-${kver}.rpm kernel-dev.rpm
    mv kernel-${kver%.*}.src.rpm kernel-src.rpm
    popd > /dev/null

    build_from_source_rpms "${tmpdir}" "${kver}" "${kconf}"
}

build_fc_module() {
    local tmpdir="$1"
    local kver="$2"
    local kconf="$3"

    build_koji_module "${tmpdir}" "${kver}" "${kconf}" "fedora"
}

build_vanilla_module() {
    local tmpdir="$1"
    local kver="$2"
    local kconf="$3"
    local dotconfig="$4"

    pushd ${tmpdir} > /dev/null
    tarball="linux-${kver%%-*}.tar.xz"
    url="https://cdn.kernel.org/pub/linux/kernel/v${kver:0:1}.x/${tarball}"
    echo "Downloading ${url}"
    curl -LO# "${url}"
    mkdir -p build/kernel
    tar -C build/kernel -xf ${tarball}
    cp ${dotconfig} dev/.config
    popd > /dev/null

    build_kernel_module "${tmpdir}" "${kver}" "${kconf}"
}

main() {
    local kver
    local kconf
    local outdir
    local koji_profile
    local dotconfig

    while getopts "d:v:c:j:o:" OPTION
    do
        case ${OPTION} in
            d)
                dotconfig=${OPTARG}
                ;;
            v)
                kver=${OPTARG}
                ;;
            c)
                kconf=${OPTARG}
                ;;
            j)
                koji_profile=${OPTARG}
                ;;
            o)
                outdir=${OPTARG}
                ;;
        esac
    done

    kver=${kver:-$(uname -r)}  # default kernel version

    echo "Building ${kconf} for kernel ${kver}"

    tmpdir=$(mktemp -d)
    mkdir -p ${tmpdir}/{src,dev,build} ${outdir}

    if [[ -n ${dotconfig} ]]; then
        build_vanilla_module "${tmpdir}" "${kver}" "${kconf}" "${dotconfig}"
    else
        if [[ -n ${koji_profile} ]]; then
            build_koji_module "${tmpdir}" "${kver}" "${kconf}" "${koji_profile}"
        else
            dist=$(awk -F. '{print $(NF-1)}' <<< ${kver})
            build_${dist%%[0-9]*}_module "${tmpdir}" "${kver}" "${kconf}"
        fi
    fi

    find ${tmpdir}/build -name "*.ko" -exec cp -v {} ${outdir} \;
    rm -rf ${tmpdir}
}

main "$@"
