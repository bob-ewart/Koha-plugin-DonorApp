DROP TABLE IF EXISTS `bodaaccts`;
CREATE TABLE `bodaaccts` (  `donacct` varchar(16) NOT NULL DEFAULT '0',  `acctdesc` varchar(80) DEFAULT NULL,  `deductible` tinyint(1) DEFAULT '0',  `level` int(11) DEFAULT '1',  `map_to` varchar(16) DEFAULT NULL,  `incexp` int(11) DEFAULT '0',  `qb` tinyint(1) DEFAULT '1',  PRIMARY KEY (`donacct`),  UNIQUE KEY `donacct` (`donacct`)) ENGINE=InnoDB DEFAULT CHARSET=utf8;
DROP TABLE IF EXISTS `bodacontact`;
CREATE TABLE `bodacontact` (  `pcardnumber` varchar(16) DEFAULT NULL,  `ucardnumber` varchar(16) DEFAULT NULL,  `lastupdate` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,  `comments` text,  KEY `pcardnumber` (`pcardnumber`)) ENGINE=InnoDB DEFAULT CHARSET=utf8;
DROP TABLE IF EXISTS `bodadonations`;
CREATE TABLE `bodadonations` (  `fund` varchar(16) DEFAULT NULL,  `cardnumber` varchar(16) NOT NULL,  `lastupdate` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,  `dondate` date NOT NULL,  `donamt` decimal(10,2) NOT NULL DEFAULT '0.00',  `donacct` varchar(16) NOT NULL,  `description` varchar(250) DEFAULT NULL,  `reference` varchar(16) DEFAULT NULL,  `jobid` varchar(32) DEFAULT NULL,  KEY `cardnumber` (`cardnumber`)) ENGINE=InnoDB DEFAULT CHARSET=utf8;
DROP TABLE IF EXISTS `bodafunds`;
CREATE TABLE `bodafunds` (  `QBname` varchar(80) DEFAULT NULL,  `fundCard` varchar(16) DEFAULT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8;
DROP TABLE IF EXISTS `bodalog`;
CREATE TABLE `bodalog` (  `loggedon` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',  `snuser` varchar(75) NOT NULL,  PRIMARY KEY (`loggedon`)) ENGINE=InnoDB DEFAULT CHARSET=utf8;
DROP TABLE IF EXISTS `bodareports`;
CREATE TABLE `bodareports` (  `repid` int(11) NOT NULL AUTO_INCREMENT,  `creator` varchar(16) NOT NULL,  `date_created` datetime DEFAULT NULL,  `modified_by` varchar(16) DEFAULT NULL,  `last_modified` datetime DEFAULT NULL,  `savedsql` text,  `last_run` datetime DEFAULT NULL,  `report_name` varchar(255) DEFAULT NULL,  `notes` text,  `expfrom` date DEFAULT NULL,  `expto` date DEFAULT NULL,  `donfrom` date DEFAULT NULL,  `donto` date DEFAULT NULL,  `zipfrom` text,  `zipto` text,  `email` text,  `lowamt` decimal(10,2) DEFAULT NULL,  `highamt` decimal(10,2) DEFAULT NULL,  `field` varchar(255) DEFAULT NULL,  `acctlim` varchar(255) DEFAULT NULL,  `catcodes` varchar(255) DEFAULT NULL,  `selcodes` varchar(255) DEFAULT NULL,  `branches` varchar(255) DEFAULT NULL,  `tottype` enum('total','individual','none') DEFAULT NULL,  `orderby` enum('card','surname','total','zip') DEFAULT 'card',  `searchdesc` varchar(80) DEFAULT NULL,  PRIMARY KEY (`repid`),  KEY `repname` (`report_name`)) ENGINE=InnoDB AUTO_INCREMENT=32 DEFAULT CHARSET=utf8;
DROP TABLE IF EXISTS `bodasystem`;
CREATE TABLE `bodasystem` (  `name` tinytext,  `internal` char(16) DEFAULT NULL,  `type` char(16) NOT NULL,  `value` tinytext) ENGINE=InnoDB DEFAULT CHARSET=utf8;
DROP TABLE IF EXISTS `bodatrace`;
CREATE TABLE `bodatrace` (  `ts` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,  `action` char(32) DEFAULT NULL,  `subaction` char(32) DEFAULT NULL,  `parm` text,  `tid` int(11) NOT NULL AUTO_INCREMENT,  PRIMARY KEY (`tid`)) ENGINE=InnoDB AUTO_INCREMENT=23 DEFAULT CHARSET=utf8;
DROP TABLE IF EXISTS `bodausers`;
CREATE TABLE `bodausers` (  `cardnumber` varchar(16) NOT NULL,  `snuser` varchar(75) NOT NULL,  `permissions`set('donate','contact','group','system') DEFAULT NULL,  UNIQUE KEY `cardnumber` (`cardnumber`),  UNIQUE KEY `snuser` (`snuser`)) ENGINE=InnoDB DEFAULT CHARSET=utf8;