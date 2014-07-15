FROM centos
MAINTAINER Takehiro Iyatomi <iyatomi@gmail.com>
RUN yum -y install git
RUN yum -y install gcc
RUN yum -y install which
RUN yum -y install --enablerepo=centosplus openssl-devel
RUN yum -y install wget
RUN yum -y install tar
RUN yum -y install zip
RUN yum -y install unzip
RUN yum -y install sudo
RUN git clone https://github.com/umegaya/pulpo.git /tmp/pulpo
RUN FROM_DOCKER=y bash /tmp/pulpo/test/tools/travis_install.sh
RUN git config --global user.email "iyatomi@gmail.com"
RUN git config --global user.name "takehiro iyatomi"
RUN yum -y install gcc-g++
RUN bash /tmp/pulpo/test/tools/bench_install.sh
