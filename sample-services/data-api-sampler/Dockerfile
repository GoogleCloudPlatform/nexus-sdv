# --- Stage 1: Build ---
ARG DOCKER_HUB_MIRROR=europe-west4-docker.pkg.dev/horizon-sdv-lal/docker-hub
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
