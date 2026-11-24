# InstantOn image.
# checkpoint.sh must stay the last instruction. It starts the server, checkpoints
# the process after the application starts, and stores that snapshot as the final
# image layer. Build with Podman and the capabilities in scripts/build-instanton.sh.
# Docker cannot grant those capabilities to a build step.



FROM docker.io/library/maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY pom.xml .
COPY src ./src
RUN mvn -B -DskipTests package

FROM icr.io/appcafe/open-liberty:kernel-slim-java17-openj9-ubi

COPY --chown=1001:0 src/main/liberty/config/server.xml /config/server.xml
RUN features.sh

COPY --chown=1001:0 --from=build /src/target/instanton-demo.war /config/apps/
RUN configure.sh

RUN checkpoint.sh afterAppStart
