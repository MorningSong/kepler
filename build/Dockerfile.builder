FROM registry.access.redhat.com/ubi9/go-toolset:1.20 as builder

USER 0

RUN yum -y install yum-utils
RUN yum-config-manager --enable ubi-9-baseos-source

WORKDIR /elfutils-source
RUN yumdownloader --source elfutils
RUN yum -y install cpio
RUN rpm2cpio elfutils-0.189-3.el9.src.rpm | cpio -iv
RUN tar xjvf elfutils-0.189.tar.bz2
WORKDIR /elfutils-source/elfutils-0.189
RUN ./configure --disable-debuginfod
RUN make install


WORKDIR /libbpf-source
RUN yumdownloader --source libbpf
RUN rpm2cpio libbpf-1.2.0-1.el9.src.rpm | cpio -iv
RUN tar xf ./linux-*el9.tar.xz
WORKDIR /libbpf-source/linux-5.14.0-333.el9/tools/lib/bpf
RUN make install_headers
RUN prefix=/usr BUILD_STATIC_ONLY=y make install
WORKDIR /libbpf-source/linux-5.14.0-333.el9/tools/bpf
RUN make bpftool

RUN yum -y install clang rpm-build llvm-devel

# enable EPEL and install cpuid
RUN yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
RUN yum install -y cpuid
RUN yum clean all
