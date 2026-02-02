# Data API Sampler

The **Data API Sampler** is a lightweight Spring Boot application designed to demonstrate how to integrate a service
with the **Nexus SDV Data API**. It provides a simplified REST interface to fetch vehicle data based on a Vehicle
Identification Number (VIN) and specific Data Types.

---

## Getting Started

### Prerequisites

* **Java SDK 21** (The Module is implemented with OpenJDK 21)

### Local Installation & Setup

1. **Clone the repository** and navigate to the project root:
   ```bash 
   cd sample-services/data-api-sampler
2. Build the project: This will generate necessary resources, build the JAR, and run all tests.

   ```bash  
   ./mvnw clean install

3. Launch the Application:

   ```bash
      ./mvnw spring-boot:run -Dspring-boot.run.arguments="--data-api.client.data-api-url=<address:port>"

---

## API Reference

---

#### Health Check

**URL:** /health

**Method:** GET

**Description:** Returns the current status of the sampler service.

---

#### Fetch Vehicle Data

**URL:** /data/{vin}/datatypes/{datatype}

**Method:** GET

**Query Params:** * lookback (optional): Defines the timespan to look back for data.

**Description:** Creates a request to the data-api via grpc and returns its data

**Examples:**

GET /data/VEHICLE001/datatypes/dynamic:battery.temp

GET /data/VEHICLE001/datatypes/dynamic:battery.temp?lookback=1d

---

## Configuration & Deployment

**Environment Management**
All configuration is handled via src/main/resources/application.properties.

**Note:** These properties are designed to be overwritten during the deployment process.

**Deployment Information**
For details on how this application is deployed and managed in the sandbox environment, please refer to the
Infrastructure as Code repository: 

👉 valtech-sdv-sandbox/iac