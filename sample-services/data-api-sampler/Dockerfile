# --- Stage 1: Build ---
# Base-image registry, supplied by the deployment chain: the Cloud Build
# pipeline passes --build-arg DOCKER_HUB_MIRROR=<project registry>/docker-hub,
# derived from IMAGE_REPO, so images always come from the deploying project's
# own Artifact Registry. Intentionally has no default — a hardcoded one named a
# registry only one project can read.
ARG DOCKER_HUB_MIRROR
FROM --platform=$BUILDPLATFORM ${DOCKER_HUB_MIRROR}/maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app

COPY pom.xml .

RUN mvn dependency:go-offline -B

COPY src ./src

# remove '-DskipTests' to execute tests
RUN mvn clean package -DskipTests

# --- Stage 2: Runtime ---
FROM ${DOCKER_HUB_MIRROR}/eclipse-temurin:21-jre
WORKDIR /app

COPY --from=build /app/target/*.jar app.jar

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "app.jar"]
