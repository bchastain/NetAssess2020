require(shiny,quietly=TRUE)

shinyServer(function(input,output,session) {
  showLoading <- function() { session$sendCustomMessage("loading","show") }
  hideLoading <- function() { session$sendCustomMessage("loading","hide") }
  
  pollutantSites <- reactive({
    if (is.null(input$pollutantSelect)) { return() }
    if (input$pollutantSelect == "none") { return() }
    return(dbGetQuery(db,paste(
      "SELECT DISTINCT sites.* 
         FROM monitors, sites, standards
        WHERE monitors.key = sites.key
          AND monitors.parameter_code = standards.parameter_code
          AND standards.pollutant = '",input$pollutantSelect,"'",sep="")))
  })
  
  newSites.df <- reactive({
    if (length(input$newSites) == 0) { return() }
    return(data.frame(key=lapply(input$newSites,function(x) x$key),
     latitude=lapply(input$newSites,function(x) x$lat),
     longitude=lapply(input$newSites,function(x) x$lng)))
  })
  
  visibleSites <- reactive({
    sites <- pollutantSites()
    if (is.null(sites)) { return() }
    ss <- sites[sites$key %in% input$visibleSites,c("key","latitude","longitude")]
    ns <- newSites.df()
    if(!is.null(ns)) {
      ss <- rbind(ss,ns[ns$key %in% input$visibleNewSites,])
    }
    return(ss)
  })
  
  activeSites <- reactive({
    selSites <- input$selectedSites
    visSites <- input$visibleSites
    return(intersect(selSites,visSites))
  })
  activeNewSites <- reactive({
    selSites <- input$selectedNewSites
    visSites <- input$visibleNewSites
    return(intersect(selSites,visSites))
  })
  
  areaOfInterest <- reactive({
    aoi <- input$areaOfInterest[[1]]
    if(is.null(names(aoi[[1]]))) {
      polygons <- lapply(aoi,function(p) {
        m <- matrix(as.numeric(do.call(rbind,p)),ncol=2)
        Polygon(coords=rbind(m,m[1,])[,c(2,1)],hole=FALSE)
      })
    } else {
      m <- matrix(as.numeric(do.call(rbind,aoi)),ncol=2)
      polygons <- list(Polygon(coords=rbind(m,m[1,])[,c(2,1)],hole=FALSE))
    }
    polygons <- SpatialPolygons(list(Polygons(polygons,"aoi")))
    return(polygons)
  })
  
  observe({
    if (is.null(pollutantSites())) { keys <- list() 
    } else { keys <- unique(pollutantSites()$key) }
    session$sendCustomMessage(type="updateVisibleMonitors",keys)
  })
  
  observe({
    if(is.null(input$areaSelect)) { return() }
    if(input$areaSelect == "State") {
      states <- unique(dbGetQuery(db,"SELECT CODE, NAME FROM states"))
      choices <- states$CODE
      names(choices) <- states$NAME
    } else if(input$areaSelect == "CBSA") {
      cbsa <- dbGetQuery(db,"SELECT CODE, NAME FROM cbsas")
      choices <- cbsa$CODE
      names(choices) <- cbsa$NAME
    } else if(input$areaSelect == "CSA") {
      csa <- dbGetQuery(db,"SELECT CODE, NAME FROM csas")
      choices <- csa$CODE
      names(choices) <- csa$NAME
    } else {
      choices <- c("")
    }
    updateSelectInput(session,"areaSelectSelect",choices=choices)
  })
  
  observe({
    if(!is.null(input$areaSelectSelect) && input$areaSelectSelect != "") {
      type <- toupper(isolate(input$areaSelect))
      src <- switch(type,STATE="states",CBSA="cbsas",CSA="csas")
      q <- paste0("SELECT GEOMETRY FROM ",src," WHERE CODE = '",input$areaSelectSelect,"'")
      coords <- eval(parse(text=dbGetQuery(db,q)[1,1]))
      session$sendCustomMessage(type="displayPredefinedArea",
        list(properties=list(name="test",type=type,id=input$areaSelectSelect),coords=coords))
    }
  })
  
  ## Area Served ##
  selectedSites <- reactive({
    sites <- pollutantSites()
    ns <- newSites.df()
    if (is.null(sites)) { return() }
    ss <- sites[sites$key %in% activeSites(),c("key","latitude","longitude")]
    if(!is.null(ns)) { ss <- rbind(ss,ns[ns$key %in% activeNewSites(),]) }
    return(ss)
  })
  
  selectedNeighbors <- reactive({
    all.sites <- visibleSites()
    ss <- selectedSites()
    if (is.null(ss)) { return() }
    if (nrow(ss) == 0) { return() }
    us.lat <- c(24.4,49.4); us.lon <- c(-124.8,-66.9);
    lat <- range(ss$latitude); lon <- range(ss$longitude);
    lat.rng <- max(abs(lat[2]-lat[1]),1); lon.rng <- max(abs(lon[2]-lon[1]),1);
    gtG <- FALSE
    while(!gtG) {
      lat.test <- c(lat[1]-lat.rng,lat[2]+lat.rng)
      lon.test <- c(lon[1]-lon.rng,lon[2]+lon.rng)
      bounds <- list(north=lat.test[2] >= us.lat[2],south=lat.test[1] <= us.lat[1],
        east=lon.test[2] >= us.lon[2],west=lon.test[1] <= us.lon[1])
      neighbors <- unique(all.sites[
        all.sites$latitude >= lat.test[1] & all.sites$latitude <= lat.test[2] &
        all.sites$longitude >= lon.test[1] & all.sites$longitude <= lon.test[2],])
      if(!bounds$north) {
        n <- neighbors[neighbors$latitude > lat[2],]
        bounds$north <- (sum(n$longitude > lon[2]) > 0 & sum(n$longitude < lon[1]) > 0 &
          sum(n$longitude < lon[2] & n$longitude > lon[1]) > 0)
      }
      if(!bounds$south) {
        n <- neighbors[neighbors$latitude < lat[1],]
        bounds$south <- (sum(n$longitude > lon[2]) > 0 & sum(n$longitude < lon[1]) > 0 &
          sum(n$longitude < lon[2] & n$longitude > lon[1]) > 0)
      }
      if(!bounds$east) {
        n <- neighbors[neighbors$longitude > lon[2],]
        bounds$east <- (sum(n$latitude > lat[2]) > 0 & sum(n$latitude < lat[1]) > 0 &
          sum(n$latitude < lat[2] & n$latitude > lat[1]) > 0)
      }
      if(!bounds$west) {
        n <- neighbors[neighbors$longitude < lon[1],]
        bounds$west <- (sum(n$latitude > lat[2]) > 0 & sum(n$latitude < lat[1]) > 0 &
          sum(n$latitude < lat[2] & n$latitude > lat[1]) > 0)
      }
      gtG <- bounds$north & bounds$south & bounds$east & bounds$west
      lat.rng <- lat.rng*2; lon.rng <- lon.rng*2;
    }
    neighbors <- neighbors[!duplicated(neighbors[,c("latitude","longitude")]),]
    v <- deldir(neighbors$longitude,neighbors$latitude)$delsgs
    v$ind1 <- neighbors$key[v$ind1]; v$ind2 <- neighbors$key[v$ind2];
    v <- v[v$ind1 %in% ss$key | v$ind2 %in% ss$key,]
    v <- unique(c(v$ind1,v$ind2))
    return(neighbors[neighbors$key %in% v,])
  })
  
  polygons <- eventReactive(input$areaServedButton,{
    ss <- isolate(selectedSites())
    if (is.null(ss)) { return() }
    if (nrow(ss) == 0) { return() }
    sn <- isolate(selectedNeighbors())
    if (is.null(sn)) { return() }
    if (nrow(sn) > 400 | nrow(sn) < 2) { return() }
    if (is.null(input$areaServedClipping)) { return() }
    if (input$areaServedClipping == "border") { b <- usborder }
    if (input$areaServedClipping == "aoi") { b <- areaOfInterest() }
    prob.bin <- function(p) {
      mp <- as.numeric(ifelse(all(is.na(p)),NA,max(p,na.rm=TRUE)))
      out <- as.character(cut(mp,breaks=c(-0.01,0.1,0.25,0.5,0.75,0.9,1.01),
        labels=c("<10%","10%-25%","25%-50%","50%-75%","75%-90%",">90%")))
      return(out)
    }
    points <- SpatialPointsDataFrame(list(sn$longitude,sn$latitude),data.frame(key=sn$key))
    bb <- bbox(rbind(t(bbox(b)),t(bbox(points))))
    tiles <- tile.list(deldir(points@coords[,1],points@coords[,2],rw=as.numeric(t(bb))))
    polys <- vector(mode="list",length=length(tiles))
    for (i in 1:length(tiles)) {
      tile.coord <- cbind(tiles[[i]]$x,tiles[[i]]$y)
      tile.coord <- rbind(tile.coord,tile.coord[1,])
      polys[[i]] <- Polygons(list(Polygon(tile.coord)),ID=sn$key[i])
    }
    polys <- gIntersection(SpatialPolygons(polys),b,byid=TRUE)
    poly.ids <- sapply(slot(polys,"polygons"),function(x) slot(x,"ID"))
    poly.keys <- as.numeric(sapply(poly.ids,function(x) unlist(strsplit(x," "))[1]))
    points <- points[points$key %in% poly.keys,]
    voronoi <- SpatialPolygonsDataFrame(polys,data=data.frame(id=poly.keys,
      pnt_x=points@coords[,1],pnt_y=points@coords[,2],row.names=poly.ids))
    v <- subset(voronoi,id %in% ss$key)
    ov <- over(tracts,v)
    t <- cbind(tracts@data,ov)
    t <- t[!is.na(t$id),]
    d <- aggregate(t[,c(grep("area",colnames(t)),grep("integer",lapply(t,class)))],
      by=list(as.character(t$id)),FUN=sum,na.rm=TRUE)
    d$area <- round(d$area)
    d <- cbind(d,aggregate(t[,grep("prob",colnames(t))],
      by=list(as.character(t$id)),FUN=prob.bin)[,-1])
    v@data <- merge(v@data,d,by.x="id",by.y="Group.1",all.x=TRUE,all.y=FALSE)
    return(v)
  })
  observeEvent(input$areaServedButton,{
    if(is.null(polygons())) { return() }
    polygons <- polygons()
    v <- lapply(seq(nrow(polygons)),function(i) {
      list(id=unlist(strsplit(polygons@polygons[[i]]@ID," "))[1], 
        coords=lapply(polygons@polygons[[i]]@Polygons,function(pp) {
          apply(pp@coords,1,function(r) list(lat=r[[2]],lng=r[[1]]))
    }))})
    session$sendCustomMessage(type="updateAreaServed",v)
  })
  
  output$areaServedPollutant <- renderText({
    if (is.null(input$pollutantSelect)) { return() }
    if (input$pollutantSelect == "none") { return() }
    return(as.character(dbGetQuery(db,paste("SELECT DISTINCT poll_name FROM standards
      WHERE pollutant = '",input$pollutantSelect,"'",sep=""))))
  })
  output$areaServedMonitor <- renderText({
    sites <- pollutantSites()
    if (is.null(sites)) { return() }
    id <- sites$site_id[sites$key %in% as.numeric(input$clickedAreaServed)][1]
    if (is.na(id)) { return() }
    return(paste(substr(id,1,2),substr(id,3,5),substr(id,6,9),sep="-"))
  })
  output$areaServedArea <- renderText({
    poly <- polygons()
    if (is.null(poly)) { return() }
    area.km <- as.numeric(poly@data$area[poly@data$id == input$clickedAreaServed])
    return(paste(format(round(area.km*0.3861,0),big.mark=",")," mi<sup>2</sup> (",
      format(area.km,big.mark=",")," km<sup>2</sup>)",sep=""))
  })
  output$areaServedPopulation <- renderText({
    poly <- polygons()
    if(is.null(poly)) { return() }
    return(format(poly@data$population[poly@data$id == input$clickedAreaServed],big.mark=","))
  })
  output$areaServedDemographics <- renderPlot({
    sites <- pollutantSites()
    if (is.null(sites)) { return() }
    df <- as.data.frame(polygons()@data)
    if (nrow(df) == 0) { return() }
    pop.cols <- c("male","female","white","black","native","asian","islander","other","multiple","hispanic",
      "age_0_4","age_5_9","age_10_14","age_15_19","age_20_24","age_25_29","age_30_34","age_35_39","age_40_44",
      "age_45_49","age_50_54","age_55_59","age_60_64","age_65_69","age_70_74","age_75_79","age_80_84","age_85_up")
    colors <- c(rep("cyan",2),rep("magenta",8),rep("yellow",18))
    id <- sites$site_id[sites$key %in% as.numeric(input$clickedAreaServed)][1]
    site.id <- paste(substr(id,1,2),substr(id,3,5),substr(id,6,9),sep="-")
    bar.hgts <- unlist(df[which(df$id == input$clickedAreaServed),pop.cols])
    ymax <- 10000*ceiling(max(c(bar.hgts,10000),na.rm=TRUE)/10000)
    yspace <- 10^floor(log(ymax,base=10))/ifelse(substr(ymax,1,1) > 5,1,ifelse(substr(ymax,1,1) > 2,2,5))
    par(mar=c(10,8,2,0),las=2,cex.main=2,cex.axis=2)
    plot(x=NULL,y=NULL,type='n',axes=FALSE,xaxs='i',xlim=c(0,30),xlab="",yaxs='i',ylim=c(0,ymax),ylab="",
      main=paste("Demographics for Area Served by Site",site.id))
    axis(side=1,at=c(1,2,seq(3.5,10.5,1),seq(12,29,1)),labels=pop.cols)
    axis(side=2,at=seq(0,ymax,yspace),labels=prettyNum(sprintf("%8d",seq(0,ymax,yspace)),big.mark=","))
    rect(xleft=0,ybottom=0,xright=30,ytop=ymax,col='gray90')
    for (i in 1:length(pop.cols)) {
      xp <- i + 0.5*(i > 2) + 0.5*(i > 10)
      rect(xleft=xp-0.5,ybottom=0,xright=xp+0.5,ytop=bar.hgts[i],col=colors[i])
    }  
  },width=1200,height=900)
  output$naaqsProb <- renderText({
    if (is.null(input$pollutantSelect)) { return("Not Available") }
    if (!(input$pollutantSelect %in% c("ozone","pm25"))) { return("Not Available") }
    data <- as.data.frame(polygons())
    data <- data[data$id == input$clickedAreaServed,]
    if(input$pollutantSelect == "ozone") { return(data$ozone_prob[1]) }
    if(input$pollutantSelect == "pm25") { return(data$pm25_prob[1]) }
  })
  
  output$trendChart <- renderImage({
    if (is.null(input$pollutantSelect)) { return(list(src="images/notrend.png")) }
    if (input$pollutantSelect == "none") { return(list(src="images/notrend.png")) }
    if (is.null(input$popupID)) { return(list(src="images/notrend.png")) }
    site <- input$popupID
    poll <- input$pollutantSelect
    annual.data <- dbGetQuery(db,paste(
      "SELECT annual.pollutant AS poll,
              sites.site_id AS site_id,
              annual.year AS year,
              annual.value AS annual_value
         FROM annual, sites
        WHERE annual.key = ",site,"
          AND annual.pollutant ",switch(poll,pm25="IN ('pm25a','pm25d')",paste("= '",poll,"'",sep="")),"
          AND sites.key = ",site,sep=""))
    dv.data <- dbGetQuery(db,paste(
      "SELECT dvs.pollutant AS poll,
              sites.site_id AS site_id,
              dvs.year AS year,
              dvs.value AS design_value
         FROM dvs, sites
        WHERE dvs.key = ",site,"
          AND dvs.pollutant ",switch(poll,pm25="IN ('pm25a','pm25d')",paste("= '",poll,"'",sep="")),"
          AND sites.key = ",site,sep=""))
    site.id <- as.character(dbGetQuery(db,paste("SELECT site_id FROM sites WHERE key =",site,sep="")))
    site.id <- paste(substr(site.id,1,2),substr(site.id,3,5),substr(site.id,6,9),sep="-")
    std <- dbGetQuery(db,paste(
      "SELECT poll_name, avg_time, level, units 
         FROM standards
        WHERE pollutant = '",poll,"'
          AND year = ",switch(poll,co=1971,lead=2009,no2=2010,ozone=2015,pm10=2006,pm25=2012,so2=2010),sep=""))
    if (poll %in% c("co","lead")) { std <- std[2,] }
    curr.year <- as.numeric(substr(Sys.Date(),1,4)) - ifelse(as.numeric(substr(Sys.Date(),6,7)) > 4,1,2)
    max.na <- function(x) { return(ifelse(all(is.na(x)),NA,max(x,na.rm=TRUE))) }
    ymax <- pmax(1.2*max.na(annual.data$annual_value),1.2*max(std$level),na.rm=TRUE)
    file.name <- paste("images/temp/trend_",site,poll,".png",sep="")
    png(filename=paste("www",file.name,sep="/"),width=1200,height=900)
    par(mar=c(6,6,2,1),mgp=c(4.5,1,0),cex.axis=2,cex.lab=2,cex.main=2,las=2)
    plot(x=NULL,y=NULL,type='n',xaxs='i',xaxt='n',xlim=c(1999.8,(curr.year+0.2)),xlab="",
      yaxs='i',ylim=c(0,ymax),ylab=paste("Concentration (",std$units[1],")",sep=""),
      main=paste(ifelse(poll == "pm25","",std$avg_time),std$poll_name[1],
        "Trend for AQS Site ID =",site.id))
    axis(side=1,at=c(2000:curr.year),labels=c(2000:curr.year))
    rect(xleft=1999.8,xright=(curr.year+0.2),ybottom=0,ytop=ymax,col="grey85")
    abline(h=seq(par("yaxp")[1],par("yaxp")[2],length.out=(par("yaxp")[3]+1)),col="white")
    abline(h=std$level[1],lty=1,lwd=2,col="black"); box();
    legend.args <- data.frame(col="black",lty=1,pch=NA,legend="NAAQS Level")
    if (poll == "pm25") {
      legend.args$legend <- "24-hour NAAQS Level"
      abline(h=std$level[2],lty=2,lwd=2,col="black")
      legend.args <- rbind(legend.args,
        data.frame(col="black",lty=2,pch=NA,legend="Annual NAAQS Level"))
      t1 <- subset(annual.data,poll == "pm25d")
      t2 <- subset(dv.data,poll == "pm25d")
      if (nrow(t1) > 0) {
        lines(x=t1$year,y=t1$annual_value,lty=2,lwd=2,col="red")
        points(x=t1$year,y=t1$annual_value,pch=15,cex=1.5,col="red")
        legend.args <- rbind(legend.args,
          data.frame(col="red",lty=2,pch=15,legend="Annual 98th Percentile"))
      }
      if (nrow(t2) > 0) {
        lines(x=t2$year,y=t2$design_value,lty=1,lwd=2,col="red")
        points(x=t2$year,y=t2$design_value,pch=16,cex=1.5,col="red")
        legend.args <- rbind(legend.args,
          data.frame(col="red",lty=1,pch=16,legend="24-hour Design Value"))
      }
      annual.data <- subset(annual.data,poll == "pm25a")
      dv.data <- subset(dv.data,poll == "pm25a")
    }
    if (poll != "lead" & nrow(annual.data) > 0) {
      lines(x=annual.data$year,y=annual.data$annual_value,lty=2,lwd=2,col="blue")
      points(x=annual.data$year,y=annual.data$annual_value,pch=15,cex=1.5,col="blue")
      legend.args <- rbind(legend.args,data.frame(col="blue",lty=2,pch=15,
        legend=paste("Annual",switch(poll,co="2nd Maximum",no2="98th Percentile",
        ozone="4th Maximum",pm10="2nd Maximum",pm25="Mean",so2="99th Percentile"))))
    }
    if (poll != "co" & nrow(dv.data) > 0) {
      lines(x=dv.data$year,y=dv.data$design_value,lty=1,lwd=2,col="blue")
      points(x=dv.data$year,y=dv.data$design_value,pch=16,cex=1.5,col="blue")
      legend.args <- rbind(legend.args,data.frame(col="blue",lty=1,pch=16,
        legend=paste(ifelse(poll == "pm25","Annual ",""),"Design Value",sep="")))
    }
    legend(x="top",legend=legend.args$legend,col=legend.args$col,lty=legend.args$lty,
      lwd=2,pch=legend.args$pch,cex=2,ncol=3,bty='n')
    dev.off()
    session$sendCustomMessage(type="updateTrendChart",file.name)
    return(list(src=file.name))
  },deleteFile=FALSE)
  
  cormatTable <- eventReactive(input$cormatButton,{
    sites <- subset(pollutantSites(),key %in% activeSites())
    if (is.null(sites)) { return() }
    if (nrow(sites) < 2) { return() }
    showLoading()
    conc <- dbGetQuery(db,paste("
     SELECT sites.site_id AS site,
            daily.sample_date AS date,
            daily.value AS conc
       FROM daily, sites
      WHERE daily.key = sites.key
        AND daily.pollutant = '",input$pollutantSelect,"'
        AND sites.site_id IN ('",paste(sites$site_id,collapse="','"),"')
      ORDER BY 1,2",sep=""))
    if (nrow(conc) == 0) { hideLoading(); return(); }
    sites <- subset(sites,site_id %in% unique(conc$site))
    mean.na <- function(x) { return(ifelse(all(is.na(x)),NA,mean(x,na.rm=TRUE))) }
    lambert <- as.data.frame(spTransform(SpatialPoints(sites[c("longitude","latitude")],
      proj4string=CRS("+proj=longlat")),CRS("+proj=lcc +lat_1=33n +lat_2=45n +lat_0=40 +lon_0=-97")))
    dist.km <- round(rdist(lambert/1000))
    values <- dcast(conc,date ~ site,value.var="conc")
    cor.val <- round(cor(values[,-1],use="pairwise.complete.obs",method="pearson"),4)
    cor.table <- vector("list",(nrow(sites)*(nrow(sites)-1)/2)); k <- 1;
    for (i in 1:(nrow(sites)-1)) {
      for (j in (i+1):nrow(sites)) {
        cor.table[[k]] <- data.frame(site1=sites$site_id[i],site2=sites$site_id[j],
          dist=dist.km[i,j],obs=sum(!is.na(values[,(i+1)]) & !is.na(values[,(j+1)])),
          cor=cor.val[i,j],diff=round(mean.na(abs(values[,(i+1)] - values[,(j+1)])),4))
        k <- k + 1
      }
    }
    hideLoading()
    return(as.data.frame(rbindlist(cor.table)))
  })
  
  output$cormatChart <- renderPlot({
    input$cormatButton
    if (input$cormatButton == 0) { return() }
    isolate({
      cor.table <- cormatTable()
      if (is.null(cor.table)) { return() }
      if (nrow(cor.table) > 800) { return() }
      poll <- as.character(dbGetQuery(db,paste("SELECT DISTINCT poll_name FROM standards
        WHERE pollutant = '",input$pollutantSelect,"'",sep="")))
      aoi <- "Custom"
      if (!is.null(input$areaSelect) & !is.null(input$areaSelectSelect)) {
        if (input$areaSelect != "none" & input$areaSelectSelect != "") { 
          aoi <- as.character(dbGetQuery(db,paste("SELECT NAME FROM ",
            switch(tolower(input$areaSelect),state="states",cbsa="cbsas",csa="csas"),"
            WHERE CODE = '",input$areaSelectSelect,"'",sep="")))
        }
      }
      unit <- as.character(dbGetQuery(db,paste("SELECT DISTINCT units FROM standards
        WHERE pollutant = '",input$pollutantSelect,"'",sep="")))
      curr.year <- as.numeric(substr(Sys.Date(),1,4)) - 
        ifelse(as.numeric(substr(Sys.Date(),6,7)) > 4,1,2)
      ids <- unique(c(cor.table$site1,cor.table$site2)); N <- length(ids);
      dvs <- dbGetQuery(db,paste(
        "SELECT sites.site_id, dvs.pollutant, dvs.value
           FROM dvs, sites
          WHERE dvs.key = sites.key
            AND dvs.pollutant ",switch(input$pollutantSelect,pm25="IN ('pm25a','pm25d')",
                paste("= '",input$pollutantSelect,"'",sep="")),"
            AND sites.site_id IN ('",paste(ids,collapse="','"),"')
            AND dvs.year = ",curr.year,"
          ORDER BY 1",sep=""))
      if (poll == "PM2.5") { dvs <- dcast(dvs,site_id ~ pollutant) }
      cor.diff <- obs.dist <- matrix(NA,nrow=N,ncol=N,dimnames=list(c(ids),c(ids)))
      cor.diff[lower.tri(cor.diff)] <- cor.table$cor[order(cor.table$site1)]
      cor.diff[upper.tri(cor.diff)] <- cor.table$diff[order(cor.table$site2)]
      obs.dist[lower.tri(obs.dist)] <- cor.table$obs[order(cor.table$site1)]
      obs.dist[upper.tri(obs.dist)] <- cor.table$dist[order(cor.table$site2)]
      if (poll != "PM2.5") { 
        diag(cor.diff) <- diag(obs.dist) <- dvs$value[match(ids,dvs$site_id)]
      }
      if (poll == "PM2.5") { 
        diag(cor.diff) <- dvs$pm25a[match(ids,dvs$site_id)]
        diag(obs.dist) <- dvs$pm25d[match(ids,dvs$site_id)]
      }
      cor.colors <- colorRampPalette(c("#0000FF","#FFFFFF"))
      cor.col <- c("#0000CC",cor.colors(11)[1:10])
      cor.seq <- c(-1,seq(0,1,0.1))
      diff.colors <- colorRampPalette(c("#FFFFFF","#FF0000"))
      diff.col <- c(diff.colors(11)[2:11],"#CC0000")
      diff.max <- switch(input$pollutantSelect,co=1,lead=0.1,no2=20,ozone=0.01,
        pm10=50,pm25=10,so2=50,1)
      diff.seq <- c(seq(0,diff.max,diff.max/10),Inf)
      mar.axis <- ifelse(N > 25,7,ifelse(N > 15,10,15))
      txt.cex <- ifelse(N > 25,1.5,ifelse(N > 15,2,3))
      col.vals <- matrix("#FFFFFF",nrow=N,ncol=N,dimnames=list(c(ids),c(ids)))
      col.vals[lower.tri(col.vals)] <- sapply(cor.diff[lower.tri(cor.diff)],
        function(x) cor.col[as.integer(cut(x,breaks=cor.seq,right=FALSE))])
      col.vals[upper.tri(col.vals)] <- sapply(cor.diff[upper.tri(cor.diff)],
        function(x) diff.col[as.integer(cut(x,breaks=diff.seq,right=FALSE))])
      layout(matrix(c(1,1,2,3,4,4),3,2),widths=c(0.9,0.1),heights=c(0.5,0.42,0.08))
      par(mar=c(1,mar.axis,mar.axis,1),mgp=c(2,1,0),las=2,tcl=0,cex.axis=txt.cex)
      plot(x=NULL,y=NULL,type='n',axes=FALSE,xaxs='i',xlab="",xlim=c(0,N)+0.5,
        yaxs='i',ylab="",ylim=c(0,N)+0.5,main="")
      axis(side=2,at=N:1,labels=ids); axis(side=3,at=1:N,labels=ids);
      rect(xleft=rep(1:N,each=N)-0.5,xright=rep(1:N,each=N)+0.5,ybottom=rep(N:1,times=N)-0.5,
        ytop=rep(N:1,times=N)+0.5,col=col.vals)
      text(x=rep(1:N,each=N),y=rep(N:1,times=N),cex=txt.cex,labels=obs.dist)
      if (poll == "PM2.5") {
        rect(xleft=c(1:N)-0.5,xright=c(1:N)+0.5,ybottom=c(N:1)-0.5,ytop=c(N:1)+0.5,col="#FFFFFF")
        text(x=c(1:N),y=c(N:1),labels=paste(diag(cor.diff),diag(obs.dist),sep="/"),cex=txt.cex)
      }
      par(mar=c(0,mar.axis,0,0))
      plot(x=NULL,y=NULL,type='n',axes=FALSE,xaxs='i',xlim=c(0,1),xlab="",
        yaxs='i',ylim=c(0,1),ylab="")
      text(x=0,y=0.8,pos=4,cex=3,labels="Values in lower triangle = # of obs used in correleation")
      text(x=0,y=0.5,pos=4,cex=3,labels="Values in upper triangle = Distance in km between sites")
      text(x=0,y=0.2,pos=4,cex=3,labels="Values along the diagonal = Most recent design values")
      text(x=0.5,y=0.8,pos=4,cex=3,labels=paste("Pollutant =",poll))
      text(x=0.5,y=0.5,pos=4,cex=3,labels=paste("Area of Interest =",aoi))
      text(x=0.5,y=0.2,pos=4,cex=3,labels="To save chart, right-click and select 'Save image as...'")
      par(mar=c(2,3,1,8),mgp=c(1,1,0),cex.axis=3,cex.lab=3)
      plot(x=NULL,y=NULL,type='n',axes=FALSE,xaxs='i',xlab="",xlim=c(0,1),yaxs='i',
        ylab=paste("Mean Absolute Difference (",unit,")",sep=""),ylim=c(0,11),main="")
      rect(xleft=rep(0,11),xright=rep(1,11),ybottom=seq(0,10,1),ytop=seq(1,11,1),
        border=NA,col=diff.col)
      axis(side=4,at=seq(0,11,1),labels=diff.seq); box();
      par(mar=c(1,3,2,8),mgp=c(1,1,0),cex.axis=3,cex.lab=3)
      plot(x=NULL,y=NULL,type='n',axes=FALSE,xaxs='i',xlab="",xlim=c(0,1),
        yaxs='i',ylab="Pearson Correlation (R)",ylim=c(0,11),main="")
      rect(xleft=rep(0,11),xright=rep(1,11),ybottom=seq(0,10,1),ytop=seq(1,11,1),
        border=NA,col=cor.col)
      axis(side=4,at=seq(0,11,1),labels=cor.seq); box();
      session$sendCustomMessage("showCormat",TRUE)
    })
  },width=1600,height=1200)
  
  rembiasTable <- reactive({
    sites <- subset(pollutantSites(),key %in% activeSites())
    sn <- selectedNeighbors()
    if (is.null(sites) | is.null(sn)) { 
      session$sendCustomMessage("showAlert",list(header="Insufficient Data",
      body="No daily data could be found for sites within your area of interest.
        Please expand your area of interest, or select a different pollutant.")) 
      return()
    }
    showLoading()
    conc <- dbGetQuery(db,paste("
      SELECT key, sample_date, value FROM daily
       WHERE key IN ('",paste(sn$key,collapse="','"),"')
         AND pollutant = '",input$pollutantSelect,"'
       ORDER BY 2,3",sep=""))
    sites <- subset(sites,key %in% unique(conc$key))
    sn <- subset(sn,key %in% unique(conc$key))
    if (nrow(sites) == 0 | nrow(sn) == 0) { 
      session$sendCustomMessage("showAlert",list(header="Insufficient Data",
      body="No daily data could be found for sites within your area of interest.
        Please expand your area of interest, or select a different pollutant."))
      hideLoading()
      return()
    }
    lambert <- function(x) { return(spTransform(SpatialPoints(x,CRS("+proj=longlat")),
      CRS("+proj=lcc +lat_1=33n +lat_2=45n +lat_0=40 +lon_0=-97"))) }
    combos <- deldir(sn$longitude,sn$latitude)$delsgs
    combos$dist <- round(rdist.vec(x1=lambert(combos[,c("x1","y1")])@coords,
      x2=lambert(combos[,c("x2","y2")])@coords)/1000,3)
    combos$ind1 <- sn$key[combos$ind1]; combos$ind2 <- sn$key[combos$ind2];
    bias.table <- lapply(sites$key,function(site) {
      site.id <- sites$site_id[which(sites$key == site)]
      site.data <- subset(conc,key == site,c("sample_date","value"))
      neighbors <- subset(combos,ind1 == site | ind2 == site)
      neighbors$key <- apply(neighbors,1,function(r) {
        if(r['ind1'] == site) { return(r['ind2']) } else { return(r['ind1'])}})
      neigh.data <- subset(conc,key %in% neighbors$key,c("key","sample_date","value"))
      neigh.data$dist <- neighbors$dist[match(neigh.data$key,neighbors$key)]
      neigh.data <- subset(neigh.data,sample_date %in% site.data$sample_date) 
      values <- dcast(neigh.data,sample_date ~ key,value.var="value")
      weights <- dcast(neigh.data,sample_date ~ key,value.var="dist")
      weights[is.na(values)] <- NA
      num <- apply(values[,-1]*(1/(weights[,-1]^2)),1,sum,na.rm=TRUE)
      den <- apply(1/(weights[,-1]^2),1,sum,na.rm=TRUE)
      avg <- data.frame(sample_date=values[num > 0,1],estimate=num[den > 0]/den[den > 0])
      bias <- merge(site.data,avg,by="sample_date")
      d <- switch(input$pollutantSelect,co=1,lead=2,no2=0,ozone=3,pm10=0,pm25=1,so2=0,0)
      bias$diff <- bias$estimate - bias$value
      rdiff <- 100*(bias$diff[bias$value > 0]/bias$value[bias$value > 0])
      data.frame(key=site,site_id=site.id,bias_n=nrow(neighbors),bias_obs=nrow(bias),
        bias_mean=round(mean(bias$diff),d+1),bias_sd=round(sd(bias$diff),d+1),
        bias_min=round(min(bias$diff),d),bias_max=round(max(bias$diff),d),
        rel_mean=round(mean(rdiff),1),rel_min=round(min(rdiff)),rel_max=round(max(rdiff)))
    })
    hideLoading()
    return(as.data.frame(rbindlist(bias.table)))
  })
  
  observeEvent(input$rembiasButton,{
    validate(need(rembiasTable(),FALSE))
    isolate({ if(!is.null(rembiasTable())) {
      session$sendCustomMessage("rembiasUpdate",list(data=rembiasTable()))  
    }})
  })
  
  output$siteInfoDownload <- downloadHandler(filename=function() {
    paste("siteinfo_",input$pollutantSelect,"_",gsub("-","",gsub(":","",
      gsub(" ","_",Sys.time()))),".csv",sep="")},content=function(file) {
    poll <- input$pollutantSelect
    sites <- pollutantSites()[pollutantSites()$key %in% activeSites(),]
    if (poll != "lead") {
      annual.data <- dbGetQuery(db,paste(
        "SELECT pollutant as poll, key, year, value AS ann FROM annual
          WHERE annual.key IN ('",paste(sites$key,collapse="','"),"')
            AND annual.pollutant ",switch(poll,pm25="IN ('pm25a','pm25d')",
                paste("= '",poll,"'",sep="")),sep=""))
      if (poll == "pm25") { annual.data <- dcast(annual.data,key + poll ~ year,value.var="ann") }
      if (poll != "pm25") { annual.data <- dcast(annual.data,key ~ year,value.var="ann") }
      cols <- c(ifelse(poll == "pm25",3,2):ncol(annual.data))
      colnames(annual.data)[cols] <- paste("ann",colnames(annual.data)[cols],sep=".")
    }
    if (poll != "co") {
      dv.data <- dbGetQuery(db,paste(
        "SELECT pollutant as poll, key, year, value AS dv FROM dvs
          WHERE dvs.key IN ('",paste(sites$key,collapse="','"),"')
            AND dvs.pollutant ",switch(poll,pm25="IN ('pm25a','pm25d')",
                paste("= '",poll,"'",sep="")),sep=""))
      if (poll == "pm25") { dv.data <- dcast(dv.data,key + poll ~ year,value.var="dv") }
      if (poll != "pm25") { dv.data <- dcast(dv.data,key ~ year,value.var="dv") }
      cols <- c(ifelse(poll == "pm25",3,2):ncol(dv.data))
      colnames(dv.data)[cols] <- paste("dv",as.numeric(colnames(dv.data)[cols])-2,
        colnames(dv.data)[cols],sep=".")
    }
    if (poll == "co") { 
      colnames(annual.data) <- gsub("ann","dv",colnames(co))
      conc.data <- annual.data
    }
    if (poll == "lead") { conc.data <- dv.data }
    if (poll == "pm25") { 
      conc.data <- merge(annual.data,dv.data,by=c("key","poll"),all=TRUE)
      conc.data$poll <- sapply(conc.data$poll,function(x) ifelse(x == "pm25a","Annual","Daily"))
      colnames(conc.data)[2] <- "standard"
    }
    if (!poll %in% c("co","lead","pm25")) { 
      conc.data <- merge(annual.data,dv.data,by="key",all=TRUE)
    }
    out <- merge(sites,conc.data,by="key",all=TRUE)[,-1]
    write.csv(out,file,row.names=FALSE)
  })
  output$areaServedDownload <- downloadHandler(filename=function() {
    paste("areaserved_",input$pollutantSelect,"_",gsub("-","",gsub(":","",
      gsub(" ","_",Sys.time()))),".csv",sep="")},content=function(file) {
    pop <- polygons()@data
    sites <- dbGetQuery(db,paste("SELECT * FROM sites 
        WHERE key IN ('",paste(pop$id,collapse="', '"),"')"),sep="")
    out <- merge(sites,pop,by.x="key",by.y="id",all=TRUE)
    out <- out[,c("site_id","site_name","address","latitude","longitude",
      "epa_region","state_name","county_name","cbsa_name","csa_title",
      "area","ozone_prob","pm25_prob","population","male","female",
      "white","black","native","asian","islander","other","multiple","hispanic",
      "age_0_4","age_5_9","age_10_14","age_15_19","age_20_24","age_25_29",
      "age_30_34","age_35_39","age_40_44","age_45_49","age_50_54","age_55_59",
      "age_60_64","age_65_69","age_70_74","age_75_79","age_80_84","age_85_up")]
    colnames(out) <- c("AQS Site ID","Site Name","Address","Latitude","Longitude",
      "EPA Region","State Name","County Name","CBSA Name","CSA Name","Area (km^2)",
      "Ozone Exceedance Probability","PM2.5 Exceedance Probability","Total Population",
      "Male","Female","Caucasian/White","African/Black","Native American","Asian",
      "Pacific Islander","Other Race","Multiple Races","Hispanic/Latino",
      "Age 0 to 4","Age 5 to 9","Age 10 to 14","Age 15 to 19","Age 20 to 24","Age 25 to 29",
      "Age 30 to 34","Age 35 to 39","Age 40 to 44","Age 45 to 49","Age 50 to 54","Age 55 to 59",
      "Age 60 to 64","Age 65 to 69","Age 70 to 74","Age 75 to 79","Age 80 to 84","Age 85 and Over")
      write.csv(out,file=file,row.names=FALSE)                             
  })
  output$correlationDownload <- downloadHandler(filename=function() {
    paste("correlation_",input$pollutantSelect,"_",gsub("-","",gsub(":","",
      gsub(" ","_",Sys.time()))),".csv",sep="")},content=function(file) {
      out <- cormatTable()
      colnames(out) <- c("AQS Site ID 1","AQS Site ID 2","Distance (km)",
        "# Observations","Correlation","Mean Difference")
      write.csv(out,file,row.names=FALSE)
  })
  output$removalBiasDownload <- downloadHandler(filename=function() {
    paste("rembias_",input$pollutantSelect,"_",gsub("-","",gsub(":","",
      gsub(" ","_",Sys.time()))),".csv",sep="")},content=function(file) {
      out <- rembiasTable()
      out <- out[,c("site_id","bias_n","bias_obs","bias_mean","bias_sd",
         "bias_min","bias_max","rel_mean","rel_min","rel_max")]
      colnames(out) <- c("AQS Site ID","Neighbors Included","Daily Obs Count",
        "Mean Removal Bias","Removal Bias Standard Deviation","Min Removal Bias",
        "Max Removal Bias","Mean Relative Bias (%)","Min Relative Bias (%)",
        "Max Relative Bias (%)")
      write.csv(out,file,row.names=FALSE)
  })
  observe({input$mPTCPO*2})
})