***Overview:***

Trip analyzer is a Modul designed to showcase how the data in big table can be leveraged. It can schedule a job which analyzes different properties of the vehicledata and calculates a score based on the driving style. This calculation is done realtime for the current trip. The result is sent to nats and can be used by either the vehicle or the web-client. 
For calculation of a specific trip, there is a interface provided using specific timestamps.

For .env information check: sample-services/trip_analyzer/example.env

***Interfaces:***

* GET /health
* GET /health/liveness
* POST /schedule/{VIN}  
  curl -X POST localhost:8000/schedule/vin1
* GET /schedule
  curl -X POST localhost:8000/schedule
* DELETE /schedule/{VIN}  
  curl -X DELETE localhost:8000/schedule/vin1
* POST /trips/{VIN}?start_time{start}&end_time={end}  
  curl -X POST localhost:8000/trips/vin1?start_time=2026-04-23T12:36:00&end_time=2026-04-23T12:38:00

***Deployment:***

**From Project ROOT Directory:**

* Adapt your local .env -> see example.env
* It is recommended to delete the current deployment on gke of trip-analyzer, because gke gets confused with different revisions sometimes

1. gcloud auth login
2. gcloud projects list
3. gcloud config set project PROJECT_ID
4. gcloud builds submit --region europe-west4 --config iac/cloudbuild/build-push-deploy-trip-analyzer.yaml
   --substitutions=_ARCH=amd64

!! substitution is necessary for now!!


***Local Development:***
* Adapt/Create your .env (You can input the data-api and nats ip from your env)
* execute make install (only needed the first time)
* execute make dev
* local environment should be running