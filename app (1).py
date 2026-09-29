import os
import requests
import numpy as np
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st

# MUST BE THE VERY FIRST STREAMLIT COMMAND IN THE SCRIPT
st.set_page_config(
    page_title="Klebsiella pneumoniae AMR Intelligence Dashboard",
    page_icon="🧬",
    layout="wide",
    initial_sidebar_state="expanded"
)

# -----------------------------------------------------------------------------
# 1. LIVE BV-BRC API INTEGRATION & CACHING
# -----------------------------------------------------------------------------
@st.cache_data(ttl=3600)
def fetch_bvbrc_live_data(taxon_id="573", limit=2000):
    """Fetches public Klebsiella pneumoniae AMR records directly from BV-BRC REST API."""
    url = "https://www.bv-brc.org/api/genome_amr/"
    query = f"eq(taxon_id,{taxon_id})&select(genome_id,isolation_year,antibiotic,resistant_phenotype)&limit({limit})"
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/rqlquery+x-www-form-urlencoded"
    }
    
    try:
        response = requests.get(f"{url}?{query}", headers=headers, timeout=15)
        if response.status_code == 200:
            df = pd.DataFrame(response.json())
            if not df.empty:
                df["isolation_year"] = pd.to_numeric(df["isolation_year"], errors='coerce')
                df = df.dropna(subset=["isolation_year", "resistant_phenotype"])
                df["isolation_year"] = df["isolation_year"].astype(int)
                df = df.rename(columns={
                    "isolation_year": "Year",
                    "antibiotic": "Antibiotic_Name",
                    "resistant_phenotype": "Phenotype"
                })
                df["Resistant_Phenotype"] = (df["Phenotype"].str.upper() == "RESISTANT").astype(int)
                return df
    except Exception as e:
        pass
        
    return pd.DataFrame()

# -----------------------------------------------------------------------------
# 2. LOCAL CSV DATASET LOADING
# -----------------------------------------------------------------------------
@st.cache_data
def load_local_datasets():
    """Loads pre-processed clean CSV datasets."""
    data = {}
    files = {
        "gene_matrix": "binary_gene_matrix.csv",
        "forecasts": "forecast_2031_results.csv",
        "gene_impact": "gene_impact_scores.csv",
        "phenotypic": "phenotypic_amr_data.csv",
        "yearly_trends": "yearly_resistance_trends.csv"
    }
    
    for key, path in files.items():
        if os.path.exists(path):
            data[key] = pd.read_csv(path)
        else:
            data[key] = pd.DataFrame()
            
    return data

# Load data
local_data = load_local_datasets()
live_bvbrc_df = fetch_bvbrc_live_data()

# -----------------------------------------------------------------------------
# 3. SIDEBAR NAVIGATION & GLOBAL FILTERS
# -----------------------------------------------------------------------------
st.sidebar.title("🧬 AMR Navigation")
st.sidebar.markdown("**Klebsiella pneumoniae (Taxon 573)**")

use_live_api = st.sidebar.checkbox("Include Live BV-BRC API Stream", value=True)

pheno_df = local_data.get("phenotypic", pd.DataFrame())
if use_live_api and not live_bvbrc_df.empty:
    combined_pheno = pd.concat([pheno_df, live_bvbrc_df], ignore_index=True)
else:
    combined_pheno = pheno_df

available_drugs = sorted(combined_pheno["Antibiotic_Name"].dropna().unique().tolist()) if not combined_pheno.empty else []

st.sidebar.subheader("Filter Controls")
selected_drugs = st.sidebar.multiselect(
    "Select Antibiotic Panel(s)",
    options=available_drugs,
    default=available_drugs[:4] if len(available_drugs) >= 4 else available_drugs
)

min_yr = int(combined_pheno["Year"].min()) if not combined_pheno.empty else 1998
max_yr = int(combined_pheno["Year"].max()) if not combined_pheno.empty else 2024

selected_years = st.sidebar.slider(
    "Select Surveillance Window",
    min_value=min_yr,
    max_value=max_yr,
    value=(min_yr, max_yr)
)

tab1, tab2, tab3, tab4 = st.tabs([
    "📈 Longitudinal Resistance Trends",
    "🧬 Resistance Genes & SHAP Attribution",
    "🔮 Prophet Resistance Forecasts (2025–2031)",
    "🌐 Live BV-BRC Isolates Explorer"
])

# -----------------------------------------------------------------------------
# TAB 1: LONGITUDINAL RESISTANCE TRENDS
# -----------------------------------------------------------------------------
with tab1:
    st.header("Longitudinal Resistance Trends (1998–2024)")
    trends_df = local_data.get("yearly_trends", pd.DataFrame())
    
    if not trends_df.empty:
        filtered_trends = trends_df[
            (trends_df["Year"].between(selected_years[0], selected_years[1])) &
            (trends_df["Antibiotic_Name"].isin(selected_drugs))
        ]
        
        m1, m2, m3, m4 = st.columns(4)
        total_isolates = filtered_trends["Total_Tested"].sum() if "Total_Tested" in filtered_trends.columns else 0
        avg_res_rate = filtered_trends["Resistance_Percentage"].mean() if not filtered_trends.empty else 0
        
        m1.metric("Total Isolates Evaluated", f"{total_isolates:,}")
        m2.metric("Selected Year Range", f"{selected_years[0]} – {selected_years[1]}")
        m3.metric("Selected Antibiotics", len(selected_drugs))
        m4.metric("Mean Resistance Rate", f"{avg_res_rate:.1f}%")
        
        st.markdown("---")
        
        fig_trend = px.line(
            filtered_trends,
            x="Year",
            y="Resistance_Percentage",
            color="Antibiotic_Name",
            markers=True,
            title="Annual Resistance Rate (%) Progression per Antibiotic",
            template="plotly_white"
        )
        st.plotly_chart(fig_trend, use_container_width=True)
        
        st.subheader("Resistance Rate (%) Matrix Across Years")
        if not filtered_trends.empty:
            pivot_df = filtered_trends.pivot(index="Antibiotic_Name", columns="Year", values="Resistance_Percentage")
            fig_heatmap = px.imshow(
                pivot_df,
                labels=dict(x="Year", y="Antibiotic", color="Resistance %"),
                color_continuous_scale="Reds",
                aspect="auto"
            )
            st.plotly_chart(fig_heatmap, use_container_width=True)

# -----------------------------------------------------------------------------
# TAB 2: RESISTANCE GENES & SHAP ATTRIBUTION
# -----------------------------------------------------------------------------
with tab2:
    st.header("Genomic Determinants & SHAP Feature Importance")
    gene_impact_df = local_data.get("gene_impact", pd.DataFrame())
    gene_matrix_df = local_data.get("gene_matrix", pd.DataFrame())
    
    col_left, col_right = st.columns([1, 1])
    
    with col_left:
        st.subheader("Top Drivers of Resistance (SHAP Values)")
        if not gene_impact_df.empty:
            sorted_shap = gene_impact_df.sort_values(by="Mean_Abs_SHAP", ascending=True).tail(15)
            fig_shap = px.bar(
                sorted_shap,
                x="Mean_Abs_SHAP",
                y="Gene",
                orientation="h",
                color="Approx_Risk_Contribution_%",
                title="Top Genomic Features by Mean Absolute SHAP Impact",
                color_continuous_scale="Viridis"
            )
            st.plotly_chart(fig_shap, use_container_width=True)
            
    with col_right:
        st.subheader("Genomic Feature Prevalence Matrix")
        if not gene_matrix_df.empty:
            gene_cols = [c for c in gene_matrix_df.columns if c != "Genome_ID"]
            gene_counts = gene_matrix_df[gene_cols].sum().reset_index().rename(columns={"index": "Gene", 0: "Isolate_Count"})
            gene_counts["Prevalence_%"] = (gene_counts["Isolate_Count"] / len(gene_matrix_df)) * 100
            gene_counts = gene_counts.sort_values(by="Prevalence_%", ascending=False).head(15)
            
            fig_prev = px.bar(
                gene_counts,
                x="Gene",
                y="Prevalence_%",
                title="Top Identified Genes Prevalence across Sampled Genomes",
                color="Prevalence_%",
                color_continuous_scale="Blues"
            )
            st.plotly_chart(fig_prev, use_container_width=True)

# -----------------------------------------------------------------------------
# TAB 3: PROPHET RESISTANCE FORECASTS (2025 - 2031)
# -----------------------------------------------------------------------------
with tab3:
    st.header("Prophet Time-Series Projections (2025–2031)")
    forecast_df = local_data.get("forecasts", pd.DataFrame())
    
    if not forecast_df.empty:
        filtered_forecasts = forecast_df[forecast_df["Antibiotic_Name"].isin(selected_drugs)]
        fig_forecast = px.line(
            filtered_forecasts,
            x="Year",
            y="Forecast_Resistance_%",
            color="Antibiotic_Name",
            markers=True,
            line_dash="Forecast_Method",
            title="Projected Resistance Growth Rates (2025–2031)",
            template="plotly_dark"
        )
        st.plotly_chart(fig_forecast, use_container_width=True)

# -----------------------------------------------------------------------------
# TAB 4: LIVE BV-BRC ISOLATES EXPLORER
# -----------------------------------------------------------------------------
with tab4:
    st.header("Live BV-BRC API Surveillance Query")
    if use_live_api and not live_bvbrc_df.empty:
        st.success(f"Retrieved {len(live_bvbrc_df):,} live genome records from BV-BRC REST API.")
        bv_filtered = live_bvbrc_df[
            (live_bvbrc_df["Year"].between(selected_years[0], selected_years[1])) &
            (live_bvbrc_df["Antibiotic_Name"].isin(selected_drugs))
        ]
        fig_live = px.histogram(
            bv_filtered,
            x="Year",
            color="Phenotype",
            barmode="group",
            title="Live Isolates Resistance Breakdown per Year"
        )
        st.plotly_chart(fig_live, use_container_width=True)