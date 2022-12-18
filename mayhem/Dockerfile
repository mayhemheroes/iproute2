FROM --platform=linux/amd64 ubuntu:22.04 as builder

RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential libdb-dev bison flex pkg-config clang

COPY . /repo
WORKDIR /repo
RUN ./configure
RUN make -j8 
RUN clang++ /repo/mayhem/fuzz_get_rate.cpp -fsanitize=fuzzer,address /repo/lib/libutil.a -o /fuzz

FROM ubuntu:22.04 as package
COPY --from=builder /repo/ip/ip /
COPY --from=builder /fuzz /fuzz_get_rate
