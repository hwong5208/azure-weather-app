from fastapi import FastAPI, HTTPException, Request, Form
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse
import httpx
import os
import time
import uuid
import asyncio
import logging
from azure.data.tables import TableClient
from azure.core.exceptions import HttpResponseError, ResourceExistsError

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Vancouver Weather Microservice")

# Setup Azure Table Storage Client
STORAGE_CONN_STR = os.getenv("AZURE_STORAGE_CONNECTION_STRING")
TABLE_NAME = "sitevisits"

table_client = None
if STORAGE_CONN_STR:
    try:
        table_client = TableClient.from_connection_string(conn_str=STORAGE_CONN_STR, table_name=TABLE_NAME)
        table_client.create_table()
    except ResourceExistsError:
        pass
    except Exception as e:
        logger.warning(f"Failed to initialize Azure Table Storage: {e}")

# In-memory fallback
visited_ips = set()
total_site_visits = 0

def record_visit_to_azure(client_ip: str):
    """Synchronous function to write telemetry to Azure Table Storage"""
    if not table_client:
        return
    try:
        table_client.upsert_entity(entity={
            "PartitionKey": "unique_ips",
            "RowKey": client_ip,
            "IsUnique": True
        })
        table_client.create_entity(entity={
            "PartitionKey": "visits",
            "RowKey": str(uuid.uuid4()),
            "IP": client_ip
        })
    except Exception as e:
        logger.error(f"Error writing to Azure Table Storage: {e}")

@app.middleware("http")
async def track_visits(request: Request, call_next):
    response = await call_next(request)
    
    if request.url.path == "/":
        global total_site_visits
        total_site_visits += 1
        
        forwarded_for = request.headers.get("x-forwarded-for")
        client_ip = forwarded_for.split(",")[0] if forwarded_for else request.client.host
        
        if client_ip not in visited_ips:
            visited_ips.add(client_ip)
            
        if table_client:
            asyncio.create_task(asyncio.to_thread(record_visit_to_azure, client_ip))
            
    return response

app.mount("/static", StaticFiles(directory="static"), name="static")

@app.get("/")
async def read_index():
    return FileResponse("static/index.html")

@app.get("/api/weather")
async def get_weather():
    lat = 49.2827
    lon = -123.1207
    url = f"https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,rain,showers,snowfall,weather_code,cloud_cover,pressure_msl,surface_pressure,wind_speed_10m,wind_direction_10m,wind_gusts_10m&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=America%2FLos_Angeles&past_days=7&forecast_days=7"
    
    async with httpx.AsyncClient() as client:
        try:
            response = await client.get(url)
            response.raise_for_status()
            return response.json()
        except httpx.HTTPError as e:
            raise HTTPException(status_code=500, detail=f"Error fetching weather data: {str(e)}")

@app.get("/api/telemetry")
async def get_telemetry():
    if table_client:
        try:
            def fetch_counts():
                unique_count = len(list(table_client.query_entities("PartitionKey eq 'unique_ips'")))
                visit_count = len(list(table_client.query_entities("PartitionKey eq 'visits'")))
                return unique_count, visit_count
            
            unique_count, visit_count = await asyncio.to_thread(fetch_counts)
            return {"total_visits": visit_count, "unique_ips": unique_count}
        except Exception as e:
            logger.error(f"Failed to fetch from Azure Table: {e}")
            
    return {"total_visits": total_site_visits, "unique_ips": len(visited_ips)}

@app.get("/health")
async def health_check():
    return {"status": "healthy"}


# ─── Prometheus-compatible mock API ────────────────────────────────────────────

async def _get_counts() -> tuple[int, int]:
    """Fetch (unique_count, visit_count) from Azure Table or memory fallback."""
    unique_count = len(visited_ips)
    visit_count = total_site_visits
    if table_client:
        try:
            def fetch():
                u = len(list(table_client.query_entities("PartitionKey eq 'unique_ips'")))
                v = len(list(table_client.query_entities("PartitionKey eq 'visits'")))
                return u, v
            unique_count, visit_count = await asyncio.to_thread(fetch)
        except Exception as e:
            logger.error(f"Failed to fetch from Azure Table: {e}")
    return unique_count, visit_count


async def _parse_query(request: Request) -> str | None:
    """Extract the ?query= param from either URL params or POST form body."""
    query = request.query_params.get("query")
    if not query and request.method == "POST":
        try:
            form_data = await request.form()
            query = form_data.get("query")
        except Exception:
            pass
    return query


def _resolve_value(query: str | None, unique_count: int, visit_count: int) -> int:
    if query and "unique_visitors_total" in query:
        return unique_count
    elif query and "site_visits_total" in query:
        return visit_count
    return 0


# Required by Grafana to validate the datasource connection
@app.get("/api/v1/labels")
@app.post("/api/v1/labels")
async def prometheus_labels():
    return {
        "status": "success",
        "data": ["__name__", "job", "instance"]
    }


# Required by Grafana metric browser
@app.get("/api/v1/label/__name__/values")
async def prometheus_label_name_values():
    return {
        "status": "success",
        "data": ["site_visits_total", "unique_visitors_total"]
    }


# Grafana "Test datasource" button pings this
@app.get("/api/v1/metadata")
async def prometheus_metadata():
    return {
        "status": "success",
        "data": {
            "site_visits_total": [{"type": "gauge", "help": "Total site visits", "unit": ""}],
            "unique_visitors_total": [{"type": "gauge", "help": "Unique IP visitors", "unit": ""}]
        }
    }


# Instant query — used by Stat panels
@app.get("/api/v1/query")
@app.post("/api/v1/query")
async def prometheus_query(request: Request):
    query = await _parse_query(request)
    logger.info(f"[/api/v1/query] method={request.method} query={query}")
    unique_count, visit_count = await _get_counts()
    value = _resolve_value(query, unique_count, visit_count)

    return {
        "status": "success",
        "data": {
            "resultType": "vector",
            "result": [
                {
                    "metric": {"__name__": query or "unknown"},
                    "value": [time.time(), str(value)]
                }
            ]
        }
    }


# Range query — used by Time series / Graph panels
@app.get("/api/v1/query_range")
@app.post("/api/v1/query_range")
async def prometheus_query_range(request: Request):
    query = await _parse_query(request)
    logger.info(f"[/api/v1/query_range] method={request.method} query={query}")
    unique_count, visit_count = await _get_counts()
    value = _resolve_value(query, unique_count, visit_count)

    # Parse start/end so we fill the full requested window.
    # Grafana sends start/end in the POST form body (seconds as float strings).
    now = time.time()
    start = now - 3600  # fallback: 1 hour ago
    end = now

    try:
        form = await request.form()
        if "start" in form:
            start = float(form["start"])
        if "end" in form:
            end = float(form["end"])
    except Exception:
        pass  # GET params or parse error — use fallback window

    # Emit one data point at start, one at end so Grafana always has values
    # in the requested window. Both carry the same current metric value.
    values = [
        [start, str(value)],
        [end, str(value)],
    ]

    return {
        "status": "success",
        "data": {
            "resultType": "matrix",
            "result": [
                {
                    "metric": {"__name__": query or "unknown"},
                    "values": values
                }
            ]
        }
    }


if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", 8000))
    uvicorn.run(app, host="0.0.0.0", port=port)
